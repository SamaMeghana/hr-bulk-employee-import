CREATE DATABASE IF NOT EXISTS hrdb;
USE hrdb;

CREATE TABLE IF NOT EXISTS department_master (
  department_key  INT PRIMARY KEY,
  department_code VARCHAR(20) NOT NULL UNIQUE,
  department_name VARCHAR(100),
  is_active       BOOLEAN DEFAULT TRUE,
  created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at      TIMESTAMP NULL ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS location_master (
  location_key  INT PRIMARY KEY,
  location_code VARCHAR(20) NOT NULL UNIQUE,
  location_name VARCHAR(100),
  is_active     BOOLEAN DEFAULT TRUE,
  created_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at    TIMESTAMP NULL ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS designation_grade_master (
  designation VARCHAR(80) PRIMARY KEY,
  grade       VARCHAR(10) NOT NULL
);

CREATE TABLE IF NOT EXISTS employee_import_runs (
  run_id VARCHAR(40) PRIMARY KEY,
  file_name VARCHAR(200) NOT NULL,
  file_format VARCHAR(10) NOT NULL,
  file_checksum VARCHAR(64) NOT NULL,
  declared_count INT, parsed_count INT, inserted_count INT,
  updated_count INT, rejected_count INT, reject_percent DECIMAL(5,2),
  run_status VARCHAR(20) NOT NULL,
  reject_file_path VARCHAR(300),
  failure_reason VARCHAR(255),
  batches_completed INT DEFAULT 0,
  notification_status VARCHAR(20),
  started_at TIMESTAMP NULL, completed_at TIMESTAMP NULL,
  correlation_id VARCHAR(50),
  UNIQUE KEY uk_import_file (file_name, file_checksum)
);

CREATE TABLE IF NOT EXISTS employees (
  employee_id VARCHAR(20) PRIMARY KEY,
  first_name VARCHAR(60) NOT NULL,
  last_name VARCHAR(60) NOT NULL,
  date_of_birth DATE NOT NULL,
  date_of_joining DATE NOT NULL,
  official_email VARCHAR(150) NOT NULL UNIQUE,
  mobile VARCHAR(20),
  department_key INT NOT NULL,
  designation VARCHAR(80) NOT NULL,
  grade VARCHAR(10),
  location_key INT NOT NULL,
  employment_type VARCHAR(15) NOT NULL,
  manager_key VARCHAR(20) NULL,
  employee_status VARCHAR(15) NOT NULL,
  source_run_id VARCHAR(40),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NULL ON UPDATE CURRENT_TIMESTAMP,
  CONSTRAINT fk_emp_dept FOREIGN KEY (department_key) REFERENCES department_master (department_key),
  CONSTRAINT fk_emp_loc  FOREIGN KEY (location_key)   REFERENCES location_master (location_key),
  CONSTRAINT fk_emp_mgr  FOREIGN KEY (manager_key)    REFERENCES employees (employee_id),
  CONSTRAINT fk_emp_run  FOREIGN KEY (source_run_id)  REFERENCES employee_import_runs (run_id)
);

CREATE TABLE IF NOT EXISTS employee_import_rejects (
  reject_seq BIGINT AUTO_INCREMENT PRIMARY KEY,
  run_id VARCHAR(40) NOT NULL,
  record_index INT NOT NULL,
  employee_id VARCHAR(20),
  reject_code VARCHAR(30) NOT NULL,
  reject_reason VARCHAR(255) NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_reject_run FOREIGN KEY (run_id) REFERENCES employee_import_runs (run_id)
);

INSERT INTO department_master (department_key, department_code, department_name) VALUES
 (1,'DEPT-ENG','Engineering'), (2,'DEPT-FIN','Finance'), (3,'DEPT-HR','Human Resources')
ON DUPLICATE KEY UPDATE department_name = VALUES(department_name);
INSERT INTO location_master (location_key, location_code, location_name) VALUES
 (1,'LOC-CHN-01','Chennai'), (2,'LOC-BLR-02','Bangalore')
ON DUPLICATE KEY UPDATE location_name = VALUES(location_name);
INSERT INTO designation_grade_master (designation, grade) VALUES
 ('Senior Engineer','G5'), ('Engineer','G4'), ('Finance Analyst','G4'),
 ('HR Executive','G3'), ('Manager','G6')
ON DUPLICATE KEY UPDATE grade = VALUES(grade);

INSERT INTO employee_import_runs (run_id, file_name, file_format, file_checksum, run_status)
 VALUES ('SEED-RUN','seed','NONE','0','SEED')
ON DUPLICATE KEY UPDATE run_status = VALUES(run_status);

INSERT INTO employees (employee_id, first_name, last_name, date_of_birth, date_of_joining,
  official_email, mobile, department_key, designation, grade, location_key,
  employment_type, manager_key, employee_status, source_run_id)
VALUES
 ('EMP10002','Seed','Manager','1980-01-01','2015-01-01','seed.manager@company.com','+91-9000000000',1,'Manager','G6',1,'PERMANENT',NULL,'ACTIVE','SEED-RUN'),
 ('EMP10003','Seed','Manager3','1981-01-01','2015-01-01','m3@company.com','+91-9000000003',1,'Manager','G6',1,'PERMANENT',NULL,'ACTIVE','SEED-RUN'),
 ('EMP10005','Seed','Manager5','1982-01-01','2015-01-01','m5@company.com','+91-9000000005',3,'Manager','G6',1,'PERMANENT',NULL,'ACTIVE','SEED-RUN'),
 ('EMP10008','Seed','Manager8','1983-01-01','2015-01-01','m8@company.com','+91-9000000008',2,'Manager','G6',2,'PERMANENT',NULL,'ACTIVE','SEED-RUN')
ON DUPLICATE KEY UPDATE official_email = VALUES(official_email);
