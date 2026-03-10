--Таблица служб
CREATE TABLE Services(
    service_code SERIAL PRIMARY KEY,
    service_name VARCHAR(255) NOT NULL,
    created_date DATE DEFAULT CURRENT_DATE
);
--Таблица отделов служб
CREATE TABLE Departments(
    department_code SERIAL,
    service_code INT NOT NULL ,
    department_name VARCHAR(255) NOT NULL,
    address VARCHAR(255) NOT NULL,
    PRIMARY KEY (department_code, service_code),
    FOREIGN KEY (service_code) REFERENCES Services(service_code)
                        ON DELETE CASCADE
);
--Таблица участков
CREATE TABLE Districts(
    district_code SERIAL,
    service_code INT NOT NULL,
    department_code INT NOT NULL,
    district_name VARCHAR(255) NOT NULL,
    PRIMARY KEY (service_code, department_code, district_code),
    FOREIGN KEY (service_code, district_code)
                      REFERENCES Departments(service_code, department_code)
                      ON DELETE CASCADE
);
--Таблица домов
CREATE TABLE Houses(
    house_code SERIAL PRIMARY KEY,
    service_code INT NOT NULL,
    department_code INT NOT NULL,
    district_code INT NOT NULL,
    street VARCHAR(255) NOT NULL,
    house_number INT CHECK ( house_code > 0 ),
    building_number INT,
    FOREIGN KEY (service_code, department_code, district_code)
                   REFERENCES Districts(service_code, department_code, district_code)
                   ON DELETE CASCADE
);
--Таблица квартир
CREATE TABLE Apartments(
    apartment_code SERIAL PRIMARY KEY,
    house_code INT NOT NULL,
    apartment_number INT NOT NULL,
    living_area REAL CHECK ( living_area > 0 ),
    total_area REAL CHECK ( total_area >= living_area ),
    is_privatized BOOLEAN DEFAULT FALSE,
    has_cold_water BOOLEAN DEFAULT TRUE,
    has_hot_water BOOLEAN DEFAULT FALSE,
    has_garbage_chute BOOLEAN DEFAULT FALSE,
    has_elevator BOOLEAN DEFAULT FALSE,
    UNIQUE (house_code, apartment_number),
    FOREIGN KEY (house_code) REFERENCES Houses(house_code)
                       ON DELETE CASCADE
);
--Таблица шифров платильщика
CREATE TABLE Payer_codes(
    payer_code SERIAL PRIMARY KEY,
    payment_percentage REAL DEFAULT 100 CHECK ( payment_percentage BETWEEN 0 AND 100),
    code_name VARCHAR(255) NOT NULL
);
--Таблица жильцов
CREATE TABLE Residents(
    resident_id SERIAL PRIMARY KEY,
    apartment_code INT NOT NULL,
    full_name VARCHAR(255) NOT NULL,
    inn VARCHAR(12) NOT NULL,
    passport_data VARCHAR(100) NOT NULL,
    birth_date DATE NOT NULL,
    is_responsible_tenant BOOLEAN DEFAULT TRUE,
    payer_code INT,
    FOREIGN KEY (apartment_code) REFERENCES Apartments(apartment_code) ON DELETE CASCADE ,
    FOREIGN KEY (payer_code) REFERENCES Payer_codes(payer_code)
);
--Таблица тарифов
CREATE TABLE Tariffs (
     tariff_id SERIAL PRIMARY KEY,
     has_cold_water BOOLEAN DEFAULT FALSE,
     has_hot_water BOOLEAN DEFAULT FALSE,
     has_garbage_chute BOOLEAN DEFAULT FALSE,
     has_elevator BOOLEAN DEFAULT FALSE,
     tariff_amount DECIMAL(10,2) CHECK (tariff_amount >= 0),
     effective_from DATE NOT NULL,
     effective_to DATE,
     CHECK (effective_to IS NULL OR effective_to > effective_from)
);

-- Индексы для ускорения поиска
CREATE INDEX idx_apartments_house ON apartments(house_code);
CREATE INDEX idx_residents_apartment ON residents(apartment_code);
CREATE INDEX idx_houses_street ON houses(street);
CREATE INDEX idx_tariffs_effective ON tariffs(effective_from, effective_to);
CREATE INDEX idx_residents_payer_code ON residents(payer_code);
CREATE INDEX idx_districts_service ON districts(service_code);

--Views
--Активные тарифы
CREATE VIEW vw_active_tariffs AS
SELECT * FROM tariffs
WHERE effective_to IS NULL OR effective_to >= CURRENT_DATE;

--Данные о квартире
CREATE VIEW vw_apartment_details AS
SELECT
    a.apartment_code,
    a.apartment_number,
    h.street,
    h.house_number,
    d.district_name,
    COUNT(r.resident_id) AS resident_count
FROM apartments a
         JOIN houses h ON a.house_code = h.house_code
         JOIN districts d ON h.service_code = d.service_code
    AND h.department_code = d.department_code
    AND h.district_code = d.district_code
         LEFT JOIN residents r ON a.apartment_code = r.apartment_code
GROUP BY a.apartment_code, a.apartment_number, h.street, h.house_number, d.district_name;

CREATE OR REPLACE FUNCTION update_apartment_area()
    RETURNS TRIGGER AS $$
DECLARE
    current_tariff RECORD;
    calculated_amount DECIMAL(10,2);
BEGIN
    -- Проверяем, изменилось ли поле total_area
    IF OLD.total_area IS DISTINCT FROM NEW.total_area THEN
        -- Ищем актуальный тариф, соответствующий удобствам квартиры
        SELECT *
        INTO current_tariff
        FROM Tariffs
        WHERE has_cold_water = NEW.has_cold_water
          AND has_hot_water = NEW.has_hot_water
          AND has_garbage_chute = NEW.has_garbage_chute
          AND has_elevator = NEW.has_elevator
          AND effective_from <= CURRENT_DATE
          AND (effective_to IS NULL OR effective_to >= CURRENT_DATE)
        ORDER BY effective_from DESC
        LIMIT 1;

        -- Если тариф найден, выполняем расчёт
        IF FOUND THEN
            -- Расчёт: тариф за м2 × новая общая площадь
            calculated_amount := current_tariff.tariff_amount * NEW.total_area;

            -- Выводим информацию в лог сервера PostgreSQL
            RAISE NOTICE 'Перерасчёт для квартиры %: площадь изменена с % м² на % м².',
                NEW.apartment_code, OLD.total_area, NEW.total_area;
            RAISE NOTICE 'Найден тариф ID %: % руб./м².',
                current_tariff.tariff_id, current_tariff.tariff_amount;
            RAISE NOTICE 'Расчётная сумма квартплаты: % руб.', calculated_amount;
        ELSE
            -- Если тариф не найден, предупреждаем
            RAISE WARNING 'Для квартиры % не найден актуальный тариф. Перерасчёт невозможен.',
                NEW.apartment_code;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE VIEW vw_utility_bills AS
SELECT
    a.apartment_code,
    a.apartment_number,
    h.street,
    h.house_number,
    h.building_number,
    d.district_name AS участок,
    dep.department_name AS отдел,
    s.service_name AS служба,
    a.total_area AS общая_площадь,
    a.living_area AS жилая_площадь,
    r.full_name AS ответственный_квартиросъёмщик,
    pc.code_name AS шифр_плательщика,
    pc.payment_percentage AS процент_оплаты,
    -- Расчёт тарифа с учётом услуг квартиры
    ROUND(
            ((CASE WHEN a.has_cold_water THEN t.tariff_amount ELSE 0 END +
              CASE WHEN a.has_hot_water THEN t.tariff_amount ELSE 0 END +
              CASE WHEN a.has_garbage_chute THEN t.tariff_amount ELSE 0 END +
              CASE WHEN a.has_elevator THEN t.tariff_amount ELSE 0 END)
                 * pc.payment_percentage / 100)::numeric,
            2
    ) AS итоговая_сумма_руб
FROM apartments a
         JOIN houses h ON a.house_code = h.house_code
         JOIN districts d ON h.service_code = d.service_code
    AND h.department_code = d.department_code
    AND h.district_code = d.district_code
         JOIN departments dep ON h.service_code = dep.service_code
    AND h.department_code = dep.department_code
         JOIN services s ON h.service_code = s.service_code
         LEFT JOIN residents r ON a.apartment_code = r.apartment_code
    AND r.is_responsible_tenant = TRUE
         LEFT JOIN payer_codes pc ON r.payer_code = pc.payer_code
         CROSS JOIN tariffs t
WHERE t.effective_to IS NULL OR t.effective_to >= CURRENT_DATE;


--Отчет список жильцов на избирательный участок
CREATE VIEW vw_residents_by_district AS
SELECT
    d.district_name AS избирательный_участок,
    h.street,
    h.house_number,
    h.building_number,
    a.apartment_number,
    r.full_name AS ФИО_жильца,
    r.inn AS ИНН,
    r.passport_data AS паспортные_данные,
    r.birth_date AS дата_рождения,
    CASE WHEN r.is_responsible_tenant THEN 'Да' ELSE 'Нет' END AS ответственный_квартиросъёмщик
FROM residents r
         JOIN apartments a ON r.apartment_code = a.apartment_code
         JOIN houses h ON a.house_code = h.house_code
         JOIN districts d ON h.service_code = d.service_code
    AND h.department_code = d.department_code
    AND h.district_code = d.district_code
ORDER BY d.district_name, h.street, h.house_number, a.apartment_number, r.full_name;




