
/*
Student Name: YOUR FULL NAME
Student Number: YOUR STUDENT NUMBER
Course Code: ICT371
Assignment: Question 1 - Pharmacy Stock and Daily Sales
*/

/* =====================================================
   STEP 1: REMOVE PREVIOUS QUESTION 1 OBJECTS
   ===================================================== */

DROP VIEW IF EXISTS v_low_stock CASCADE;

DROP TABLE IF EXISTS
    sales,
    stock_audit,
    daily_sales,
    medicines
CASCADE;

DROP PROCEDURE IF EXISTS
    pr_record_sale(INTEGER, INTEGER, DATE);

DROP PROCEDURE IF EXISTS
    pr_refresh_sales(DATE);

DROP FUNCTION IF EXISTS
    fn_sale_value(INTEGER, INTEGER);

DROP FUNCTION IF EXISTS
    fn_stock_audit();


/* =====================================================
   STEP 2: CREATE THE FOUR TABLES
   ===================================================== */

CREATE TABLE medicines (
    medicine_id SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100) NOT NULL,
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty INTEGER NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL
        REFERENCES medicines(medicine_id),
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on DATE NOT NULL
);

CREATE TABLE stock_audit (
    audit_id SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL
        REFERENCES medicines(medicine_id),
    old_qty INTEGER NOT NULL,
    new_qty INTEGER NOT NULL,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_sales (
    sales_date DATE PRIMARY KEY,
    total_qty INTEGER NOT NULL DEFAULT 0,
    total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);


/* =====================================================
   STEP 3: INSERT AT LEAST THREE MEDICINES
   ===================================================== */

INSERT INTO medicines
    (medicine_name, unit_price, stock_qty)
VALUES
    ('Paracetamol', 5.00, 20),
    ('Amoxicillin', 12.00, 15),
    ('Cough Syrup', 25.00, 9);


/* =====================================================
   STEP 4: CREATE THE SALE VALUE FUNCTION
   ===================================================== */

CREATE OR REPLACE FUNCTION fn_sale_value(
    p_medicine_id INTEGER,
    p_quantity INTEGER
)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be greater than zero';
    END IF;

    SELECT unit_price
    INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Medicine ID % does not exist',
            p_medicine_id;
    END IF;

    RETURN v_price * p_quantity;
END;
$$;


/* =====================================================
   STEP 5: CREATE THE STOCK AUDIT TRIGGER FUNCTION
   ===================================================== */

CREATE OR REPLACE FUNCTION fn_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.stock_qty IS DISTINCT FROM NEW.stock_qty THEN

        INSERT INTO stock_audit (
            medicine_id,
            old_qty,
            new_qty,
            changed_at
        )
        VALUES (
            NEW.medicine_id,
            OLD.stock_qty,
            NEW.stock_qty,
            CURRENT_TIMESTAMP
        );

    END IF;

    RETURN NEW;
END;
$$;


/* =====================================================
   STEP 6: CREATE THE AFTER UPDATE TRIGGER
   ===================================================== */

CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
EXECUTE FUNCTION fn_stock_audit();


/* =====================================================
   STEP 7: CREATE THE SALE PROCEDURE
   ===================================================== */

CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INTEGER,
    p_quantity INTEGER,
    p_sold_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_stock INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Sale quantity must be greater than zero';
    END IF;

    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date cannot be NULL';
    END IF;

    SELECT unit_price, stock_qty
    INTO v_price, v_stock
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Medicine ID % does not exist',
            p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION
            'Insufficient stock. Available: %, Requested: %',
            v_stock, p_quantity;
    END IF;

    INSERT INTO sales (
        medicine_id,
        quantity,
        unit_price,
        sold_on
    )
    VALUES (
        p_medicine_id,
        p_quantity,
        v_price,
        p_sold_on
    );

    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;

END;
$$;


/* =====================================================
   STEP 8: RECORD SIX VALID SALES THROUGH THE PROCEDURE
   ===================================================== */

CALL pr_record_sale(1, 3, CURRENT_DATE);
CALL pr_record_sale(1, 2, CURRENT_DATE);

CALL pr_record_sale(2, 4, CURRENT_DATE);
CALL pr_record_sale(2, 1, CURRENT_DATE - 1);

CALL pr_record_sale(3, 2, CURRENT_DATE - 1);
CALL pr_record_sale(3, 1, CURRENT_DATE);


/* =====================================================
   STEP 9: CREATE THE LOW STOCK VIEW
   ===================================================== */

CREATE OR REPLACE VIEW v_low_stock AS
SELECT
    medicine_id,
    medicine_name,
    unit_price,
    stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;


/* =====================================================
   STEP 10: CREATE THE COMPOSITE INDEX
   ===================================================== */

CREATE INDEX idx_sales_medicine_sold_on
ON sales (medicine_id, sold_on);


/* =====================================================
   STEP 11: CREATE THE DAILY SALES REFRESH PROCEDURE
   ===================================================== */

CREATE OR REPLACE PROCEDURE pr_refresh_sales(
    p_day DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Sales date cannot be NULL';
    END IF;

    INSERT INTO daily_sales (
        sales_date,
        total_qty,
        total_amount
    )
    SELECT
        p_day,
        COALESCE(SUM(quantity), 0),
        COALESCE(SUM(quantity * unit_price), 0)
    FROM sales
    WHERE sold_on = p_day

    ON CONFLICT (sales_date)
    DO UPDATE SET
        total_qty = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;

END;
$$;


/* =====================================================
   STEP 12: GENERATE DAILY SALES SUMMARIES FOR TESTING
   ===================================================== */

CALL pr_refresh_sales(CURRENT_DATE);
CALL pr_refresh_sales(CURRENT_DATE - 1);


/* =====================================================
   STEP 13: SCHEDULE THE DAILY JOB
   Runs daily at 00:15 for the previous day.
   Requires pg_cron to be installed and configured.
   ===================================================== */

DO $$
DECLARE
    v_job_id BIGINT;
BEGIN
    BEGIN
        EXECUTE 'CREATE EXTENSION IF NOT EXISTS pg_cron';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE
            'pg_cron could not be enabled: %. The SQL work is still complete, but the job must be configured on a server that supports pg_cron.',
            SQLERRM;
    END;

    IF to_regclass('cron.job') IS NOT NULL THEN

        FOR v_job_id IN
            EXECUTE
                'SELECT jobid FROM cron.job WHERE jobname = $1'
            USING 'pharmacy-daily-sales-refresh'
        LOOP
            EXECUTE 'SELECT cron.unschedule($1)'
            USING v_job_id;
        END LOOP;

        EXECUTE
            'SELECT cron.schedule($1, $2, $3)'
        INTO v_job_id
        USING
            'pharmacy-daily-sales-refresh',
            '15 0 * * *',
            'CALL pr_refresh_sales(CURRENT_DATE - 1);';

        RAISE NOTICE
            'Daily pharmacy sales job scheduled. Job ID: %',
            v_job_id;
    ELSE
        RAISE NOTICE
            'pg_cron is not available. Ask your database administrator to enable it and run the scheduling step.';
    END IF;
END;
$$;


/* =====================================================
   STEP 14: TEST THE FUNCTION
   ===================================================== */

SELECT fn_sale_value(1, 4) AS sale_value;


/* =====================================================
   STEP 15: DISPLAY ALL MEDICINES AND REMAINING STOCK
   ===================================================== */

SELECT *
FROM medicines
ORDER BY medicine_id;


/* =====================================================
   STEP 16: DISPLAY ALL SIX SALES
   ===================================================== */

SELECT *
FROM sales
ORDER BY sale_id;


/* =====================================================
   STEP 17: DISPLAY THE STOCK AUDIT RECORDS
   ===================================================== */

SELECT *
FROM stock_audit
ORDER BY audit_id;


/* =====================================================
   STEP 18: DISPLAY THE LOW STOCK VIEW
   ===================================================== */

SELECT *
FROM v_low_stock;


/* =====================================================
   STEP 19: DISPLAY DAILY SALES TOTALS
   ===================================================== */

SELECT *
FROM daily_sales
ORDER BY sales_date;


/* =====================================================
   STEP 20: DISPLAY THE EXPLAIN PLAN FOR THE INDEX QUERY
   ===================================================== */

EXPLAIN
SELECT *
FROM sales
WHERE medicine_id = 1
AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;


/* =====================================================
   END OF QUESTION 1
   ===================================================== */
