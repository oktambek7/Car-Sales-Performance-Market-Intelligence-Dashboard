/* =========================================================
   Car Sales ETL - Staging -> Clean -> Star Schema -> Views
   ========================================================= */
------------------------------------------------------------
-- 1) STAGING: normalize types, trim text, safe casts
------------------------------------------------------------
IF OBJECT_ID('dbo.stg_car_sales', 'U') IS NOT NULL DROP TABLE dbo.stg_car_sales;

SELECT
    -- If you don't have sale_id, generate one later with ROW_NUMBER in clean step
    TRY_CAST(sale_id AS BIGINT)        AS sale_id,

    -- Date parsing: adjust if your saledate format differs
    TRY_CAST(saledate AS DATETIME)     AS sale_date,

    TRY_CAST([year] AS INT)            AS vehicle_year,
    LTRIM(RTRIM(make))                 AS make,
    LTRIM(RTRIM(model))                AS model,
    NULLIF(LTRIM(RTRIM(trim)), '')     AS trim,
    NULLIF(LTRIM(RTRIM(body)), '')     AS body_type,
    NULLIF(LTRIM(RTRIM(transmission)), '') AS transmission,

    NULLIF(LTRIM(RTRIM(vin)), '')      AS vin,
    NULLIF(LTRIM(RTRIM([state])), '')  AS state_code,

    TRY_CAST([condition] AS INT)       AS vehicle_condition,
    TRY_CAST(odometer AS BIGINT)       AS odometer,

    NULLIF(LTRIM(RTRIM(color)), '')    AS exterior_color,
    NULLIF(LTRIM(RTRIM(interior)), '') AS interior_color,
    NULLIF(LTRIM(RTRIM(seller)), '')   AS seller,

    TRY_CAST(sellingprice AS BIGINT)   AS selling_price,
    TRY_CAST(mmr AS BIGINT)            AS mmr_price
INTO dbo.stg_car_sales
FROM dbo.raw_car_sales;

------------------------------------------------------------
-- 2) CLEAN: remove impossible values, create features
------------------------------------------------------------
IF OBJECT_ID('dbo.clean_car_sales', 'U') IS NOT NULL DROP TABLE dbo.clean_car_sales;

WITH base AS (
    SELECT
        -- If sale_id is null, generate stable surrogate for modeling
        COALESCE(sale_id, ROW_NUMBER() OVER (ORDER BY (SELECT 1))) AS sale_id,

        sale_date,
        vehicle_year,
        make, model, trim,
        body_type, transmission,
        vin, state_code,
        vehicle_condition, odometer,
        exterior_color, interior_color,
        seller,
        selling_price,
        mmr_price
    FROM dbo.stg_car_sales
)
SELECT
    sale_id,
    sale_date,
    vehicle_year,
    make, model, trim,
    body_type, transmission,
    vin, state_code,
    vehicle_condition, odometer,
    exterior_color, interior_color,
    seller,
    selling_price,
    mmr_price,

    -- Core feature: price diff vs MMR
    (selling_price - mmr_price) AS price_vs_mmr,

    -- Percent difference (avoid divide-by-zero)
    CASE
      WHEN mmr_price IS NULL OR mmr_price = 0 THEN NULL
      ELSE 1.0 * (selling_price - mmr_price) / mmr_price
    END AS price_vs_mmr_pct,

    -- Pricing status label (tune thresholds to your analysis)
    CASE
      WHEN mmr_price IS NULL OR mmr_price = 0 THEN 'Unknown'
      WHEN selling_price < mmr_price * 0.98 THEN 'Underpriced'
      WHEN selling_price > mmr_price * 1.02 THEN 'Overpriced'
      ELSE 'Fair'
    END AS pricing_status,

    -- Time features for Power BI
    YEAR(sale_date)  AS sale_year,
    MONTH(sale_date) AS sale_month
INTO dbo.clean_car_sales
FROM base
WHERE 1=1
  AND sale_date IS NOT NULL
  AND selling_price IS NOT NULL AND selling_price > 0
  AND (vehicle_year IS NULL OR (vehicle_year BETWEEN 1980 AND YEAR(GETDATE()) + 1))
  AND (odometer IS NULL OR odometer BETWEEN 0 AND 500000);

------------------------------------------------------------
-- 3) STAR SCHEMA (dimensions + fact)
--    Great for Power BI performance and clean relationships.
------------------------------------------------------------

-- 3.1) DimDate
IF OBJECT_ID('dbo.dim_date', 'U') IS NOT NULL DROP TABLE dbo.dim_date;

SELECT DISTINCT
    CAST(sale_date AS DATE) AS date_key,
    YEAR(sale_date)         AS [year],
    MONTH(sale_date)        AS [month],
    DATENAME(MONTH, sale_date) AS month_name,
    DATEPART(QUARTER, sale_date) AS [quarter]
INTO dbo.dim_date
FROM dbo.clean_car_sales;

ALTER TABLE dbo.dim_date
ADD CONSTRAINT PK_dim_date PRIMARY KEY (date_key);

-- 3.2) DimVehicle
IF OBJECT_ID('dbo.dim_vehicle', 'U') IS NOT NULL DROP TABLE dbo.dim_vehicle;

SELECT
    ROW_NUMBER() OVER (ORDER BY make, model, trim, body_type, transmission, vehicle_year) AS vehicle_key,
    vehicle_year,
    make,
    model,
    trim,
    body_type,
    transmission
INTO dbo.dim_vehicle
FROM (
    SELECT DISTINCT vehicle_year, make, model, trim, body_type, transmission
    FROM dbo.clean_car_sales
) v;

ALTER TABLE dbo.dim_vehicle
ADD CONSTRAINT PK_dim_vehicle PRIMARY KEY (vehicle_key);

-- 3.3) DimSeller
IF OBJECT_ID('dbo.dim_seller', 'U') IS NOT NULL DROP TABLE dbo.dim_seller;

SELECT
    ROW_NUMBER() OVER (ORDER BY seller) AS seller_key,
    seller
INTO dbo.dim_seller
FROM (
    SELECT DISTINCT COALESCE(seller, 'Unknown') AS seller
    FROM dbo.clean_car_sales
) s;

ALTER TABLE dbo.dim_seller
ADD CONSTRAINT PK_dim_seller PRIMARY KEY (seller_key);

-- 3.4) DimLocation (State)
IF OBJECT_ID('dbo.dim_location', 'U') IS NOT NULL DROP TABLE dbo.dim_location;

SELECT
    ROW_NUMBER() OVER (ORDER BY state_code) AS location_key,
    COALESCE(state_code, 'Unknown') AS state_code
INTO dbo.dim_location
FROM (
    SELECT DISTINCT state_code
    FROM dbo.clean_car_sales
) l;

ALTER TABLE dbo.dim_location
ADD CONSTRAINT PK_dim_location PRIMARY KEY (location_key);

-- 3.5) FactSales
IF OBJECT_ID('dbo.fact_sales', 'U') IS NOT NULL DROP TABLE dbo.fact_sales;

SELECT
    c.sale_id AS sale_id,

    CAST(c.sale_date AS DATE) AS date_key,

    v.vehicle_key,
    s.seller_key,
    l.location_key,

    c.vehicle_condition,
    c.odometer,

    c.selling_price,
    c.mmr_price,
    c.price_vs_mmr,
    c.price_vs_mmr_pct,
    c.pricing_status
INTO dbo.fact_sales
FROM dbo.clean_car_sales c
JOIN dbo.dim_vehicle v
  ON v.vehicle_year = c.vehicle_year
 AND v.make = c.make
 AND v.model = c.model
 AND ISNULL(v.trim,'') = ISNULL(c.trim,'')
 AND ISNULL(v.body_type,'') = ISNULL(c.body_type,'')
 AND ISNULL(v.transmission,'') = ISNULL(c.transmission,'')

JOIN dbo.dim_seller s
  ON s.seller = COALESCE(c.seller,'Unknown')

JOIN dbo.dim_location l
  ON l.state_code = COALESCE(c.state_code,'Unknown');

ALTER TABLE dbo.fact_sales
ADD CONSTRAINT PK_fact_sales PRIMARY KEY (sale_id);

------------------------------------------------------------
-- 4) REPORTING VIEWS (Power BI-friendly)
------------------------------------------------------------

-- 4.1) Main model view (denormalized for easy import)
IF OBJECT_ID('dbo.vw_sales_model', 'V') IS NOT NULL DROP VIEW dbo.vw_sales_model;
GO
CREATE VIEW dbo.vw_sales_model AS
SELECT
    f.sale_id,
    d.date_key,
    d.[year] AS sale_year,
    d.[month] AS sale_month,
    d.month_name,
    d.[quarter],
    v.make, v.model, v.trim, v.body_type, v.transmission, v.vehicle_year,
    s.seller,
    loc.state_code,
    f.vehicle_condition,
    f.odometer,
    f.selling_price,
    f.mmr_price,
    f.price_vs_mmr,
    f.price_vs_mmr_pct,
    f.pricing_status
FROM dbo.fact_sales f
JOIN dbo.dim_date d       ON d.date_key = f.date_key
JOIN dbo.dim_vehicle v    ON v.vehicle_key = f.vehicle_key
JOIN dbo.dim_seller s     ON s.seller_key = f.seller_key
JOIN dbo.dim_location loc ON loc.location_key = f.location_key;
GO

-- 4.2) KPI view (optional)
IF OBJECT_ID('dbo.vw_kpis', 'V') IS NOT NULL DROP VIEW dbo.vw_kpis;
GO
CREATE VIEW dbo.vw_kpis AS
SELECT
    COUNT(*) AS total_sales,
    SUM(CAST(selling_price AS BIGINT)) AS total_revenue,
    AVG(CAST(selling_price AS FLOAT)) AS avg_selling_price,
    AVG(CAST(mmr_price AS FLOAT)) AS avg_mmr_price,
    AVG(CAST(price_vs_mmr AS FLOAT)) AS avg_price_vs_mmr
FROM dbo.vw_sales_model;
GO
