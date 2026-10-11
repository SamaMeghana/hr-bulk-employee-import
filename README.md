HR Bulk Employee Import – Build Guide
Oct 10, 2026 · @deepu
0. Overview: what you are building
You are building a MuleSoft 4 batch application that picks up a CSV or XML employee file, validates every record, enriches it from MySQL, writes valid records in batches, writes rejects to a reject file, and emails HR a summary. Everything below follows the NPN hackathon brief and your generator prompt, in build order.
Core design decisions (decide these once, then never revisit):
•	One canonical employee model. CSV and XML are parsed by two small DataWeave scripts that output the same array; all later logic is written once.
•	Record-level all-or-nothing: each record is validated completely before any write, and each record is written in one SQL transaction (the batch step), so a failed record never leaves a partial row.
•	Two-pass database write for forward references: Pass 1 inserts/updates every accepted employee with manager_key = NULL. Pass 2 updates manager_key once all employees exist. Ordering inside the file then never matters.
•	Validation is done in memory, before persistence, in one DataWeave module, so the threshold abort can happen before any write.
•	Privacy: logs and emails only ever contain employeeId, recordIndex, reject code and reason. Never DOB, mobile or compensation.
Runtime flow (numbered):
1.	File listener (*.csv, *.xml) fires on the inbound folder.
2.	Generate runId, compute SHA-256 checksum, check duplicate file in employee_import_runs. If seen, send duplicate email, archive, stop.
3.	File-level validation: encoding, format, header/root structure, declared record count. Failure moves the file to the error folder and sends a FAILED email.
4.	Transform to canonical array (CSV or XML script).
5.	Load reference data (departments, locations, grades, existing employees) once; cache it.
6.	Validate all records (record-validation.dwl) and tag each INSERT, UPDATE or REJECT.
7.	Threshold check. If reject percent is above 40, write the run row as ABORTED, send the failure email, write the reject file, stop before persistence.
8.	Batch Job Pass 1 (size 200, commit per batch): upsert employees without manager.
9.	Pass 2: set manager_key for each accepted record.
10.	Write the reject file in the original format with a rejectReason column or element, and save reject rows to employee_import_rejects.
11.	Update the run row, send the SUCCESS or PARTIAL email, archive the file.
Suggested 5-day plan (the brief gives 5 calendar days):
Day	Goal	Output
1	Setup, Git, DB, RAML, project skeleton	Repo, DDL run, empty flows start
2	DataWeave: both transforms plus validation	Scripts tested in the DW Playground
3	Main flows: intake, validate, batch, reject file	End-to-end happy path for CSV and XML
4	Email, errors, negative cases, logging	All 19 negative scenarios behave
5	MUnit, CloudHub deploy, policies, HLD document	100% coverage report and a demo
Step 1. Install tools and create accounts
Do this first; it takes about an hour.
1.	Create a free Anypoint Platform trial account at anypoint.mulesoft.com. Note your organization and the Sandbox environment.
2.	Install Anypoint Studio 7.x (Mule runtime 4.4 or newer) and JDK 17 (Mule 4.6+) or JDK 8/11 for older runtimes. Match the JDK to the runtime Studio ships with.
3.	Install MySQL 8 (or use a free cloud MySQL such as Aiven or a Docker container) and MySQL Workbench or DBeaver.
4.	For SMTP testing install MailHog or use Gmail with an app password. MailHog runs on localhost:1025 with a web UI on 8025; it needs no password, which makes local testing easy.
5.	Install Git and create an account on GitHub or GitLab. Install Maven if you also want command-line builds.
6.	In Studio, open Help > Install New Software and confirm the MUnit and APIkit plugins are present.
7.	Optional: install Docker so everyone on the team gets the same database with one command:
docker run -d --name hrdb -p 3306:3306 -e MYSQL_ROOT_PASSWORD=root -e MYSQL_DATABASE=hrdb mysql:8
docker run -d --name mailhog -p 1025:1025 -p 8025:8025 mailhog/mailhog
Check: mysql -h localhost -u root -p connects, and http://localhost:8025 opens the MailHog inbox.
Step 2. Create the Git repo and project structure
1.	Create an empty repository hr-bulk-employee-import on GitHub and add every team member as a collaborator.
2.	Use this branch model: main (protected, deployable), develop (integration), and feature/<name> per person. Merge only through pull requests.
3.	In Studio choose File > New > Mule Project. Name it hr-bulk-employee-import, pick the latest 4.x runtime, and uncheck "Add APIkit" for now.
4.	Create the folders exactly as below (the generator prompt expects these paths):
hr-bulk-employee-import/
  pom.xml
  mule-artifact.json
  src/main/mule/
    global-config.xml
    main-flow.xml          (file listener + orchestration)
    file-validation.xml
    parse-flows.xml        (CSV and XML parse)
    validation-flow.xml
    persistence-flow.xml   (batch job + pass 2)
    reject-flow.xml
    notification-flow.xml
    error-handler.xml
  src/main/resources/
    config/app-config-dev.yaml
    config/app-config-secure-dev.yaml
    dwl/csv-canonical-transform.dwl
    dwl/xml-canonical-transform.dwl
    dwl/record-validation.dwl
    dwl/reject-csv.dwl
    dwl/reject-xml.dwl
    dwl/email-body.dwl
    sql/ddl.sql
    api/hr-import-api.raml
  src/test/munit/*.xml
  src/test/resources/samples/*.csv *.xml
  docs/HLD.docx
  README.md
5.	Add a .gitignore containing target/, .mule/, .studio/, *.jar, and especially src/main/resources/config/*-secure-*.yaml if you use real keys.
6.	Commit and push to develop:
git init && git add . && git commit -m "chore: project skeleton"
git branch -M main && git remote add origin <your-repo-url> && git push -u origin main
git checkout -b develop && git push -u origin develop
7.	Each teammate clones, creates feature/<name>, commits small, rebases on develop, and opens a pull request. Practise one deliberate merge conflict early because the hackathon asks you to demonstrate it.
Step 3. Build the database
Create schema hrdb, then save the script below as src/main/resources/sql/ddl.sql and run it. The brief gives four tables; you must add location_master and a designation_grade_master (needed to resolve designation to grade). Order matters because of foreign keys.
CREATE DATABASE IF NOT EXISTS hrdb;
USE hrdb;

CREATE TABLE department_master (
  department_key  INT PRIMARY KEY,
  department_code VARCHAR(20) NOT NULL UNIQUE,
  department_name VARCHAR(100),
  is_active       BOOLEAN DEFAULT TRUE,
  created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at      TIMESTAMP NULL ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE location_master (
  location_key  INT PRIMARY KEY,
  location_code VARCHAR(20) NOT NULL UNIQUE,
  location_name VARCHAR(100),
  is_active     BOOLEAN DEFAULT TRUE,
  created_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at    TIMESTAMP NULL ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE designation_grade_master (
  designation VARCHAR(80) PRIMARY KEY,
  grade       VARCHAR(10) NOT NULL
);

CREATE TABLE employee_import_runs (
  run_id VARCHAR(40) PRIMARY KEY,
  file_name VARCHAR(200) NOT NULL,
  file_format VARCHAR(10) NOT NULL,
  file_checksum VARCHAR(64) NOT NULL,
  declared_count INT, parsed_count INT, inserted_count INT,
  updated_count INT, rejected_count INT, reject_percent DECIMAL(5,2),
  run_status VARCHAR(20) NOT NULL,
  reject_file_path VARCHAR(300),
  batches_completed INT DEFAULT 0,
  notification_status VARCHAR(20),
  started_at TIMESTAMP NULL, completed_at TIMESTAMP NULL,
  correlation_id VARCHAR(50),
  UNIQUE KEY uk_import_file (file_name, file_checksum)
);

CREATE TABLE employees (
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

CREATE TABLE employee_import_rejects (
  reject_seq BIGINT AUTO_INCREMENT PRIMARY KEY,
  run_id VARCHAR(40) NOT NULL,
  record_index INT NOT NULL,
  employee_id VARCHAR(20),
  reject_code VARCHAR(30) NOT NULL,
  reject_reason VARCHAR(255) NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_reject_run FOREIGN KEY (run_id) REFERENCES employee_import_runs (run_id)
);

-- Seed data
INSERT INTO department_master (department_key, department_code, department_name) VALUES
 (1,'DEPT-ENG','Engineering'), (2,'DEPT-FIN','Finance'), (3,'DEPT-HR','Human Resources');
INSERT INTO location_master (location_key, location_code, location_name) VALUES
 (1,'LOC-CHN-01','Chennai'), (2,'LOC-BLR-02','Bangalore');
INSERT INTO designation_grade_master (designation, grade) VALUES
 ('Senior Engineer','G5'), ('Engineer','G4'), ('Finance Analyst','G4'),
 ('HR Executive','G3'), ('Manager','G6');

-- Reference manager (needs a seed run row because of fk_emp_run)
INSERT INTO employee_import_runs (run_id, file_name, file_format, file_checksum, run_status)
 VALUES ('SEED-RUN','seed','NONE','0','SEED');
INSERT INTO employees (employee_id, first_name, last_name, date_of_birth, date_of_joining,
  official_email, mobile, department_key, designation, grade, location_key,
  employment_type, manager_key, employee_status, source_run_id)
VALUES ('EMP10002','Seed','Manager','1980-01-01','2015-01-01','seed.manager@company.com',
  '+91-9000000000',1,'Manager','G6',1,'PERMANENT',NULL,'ACTIVE','SEED-RUN');
Design notes:
•	run_status values: SUCCESS, PARTIAL, FAILED, ABORTED, DUPLICATE_FILE, EMPTY.
•	The seed puts EMP10002 in the database so the first sample row resolves. The sample also names managers EMP10003, EMP10005 and EMP10008, which are in neither the file nor the seed. Add three more seed employees with those IDs (copy the EMP10002 insert and change the ID, email and department) before testing, otherwise 4 of 5 rows reject and the 40% threshold aborts the run.
•	The unique (file_name, file_checksum) key is what makes duplicate file detection safe even under a race.
•	With those managers seeded, the sample file gives 4 accepted rows and 1 rejected row (EMP10045, unknown DEPT-XXX), which is a PARTIAL run at 20% rejects.
Check: SELECT COUNT(*) FROM department_master; returns 3.
Step 4. Design the API layers and RAML
The file listener drives the import, but the brief requires API-led design, RAML, APIkit and Auto Discovery. Satisfy all of them with this layout:
Layer	Mule app	Responsibility
Process API	hr-employee-import-papi	File orchestration, validation, batch logic, plus REST endpoints to check runs and re-trigger a file
System API	hr-employee-db-sapi	Only talks to MySQL (departments, locations, grades, employees, runs, rejects)
Experience API (optional)	hr-admin-portal-eapi	Simple read view for HR admins; skip if short on time
If time is tight, keep one app but still separate the DB access into its own flow file db-system-flows.xml and say in the HLD that it is a System API that would be split in production. Note that a hackathon judge will score a real split higher.
1.	Create src/main/resources/api/hr-import-api.raml:
#%RAML 1.0
title: HR Bulk Employee Import API
version: v1
baseUri: https://hr-employee-import-papi.cloudhub.io/api/v1
mediaType: application/json
types:
  Run:
    properties:
      runId: string
      fileName: string
      fileFormat: string
      runStatus: string
      declaredCount?: integer
      parsedCount?: integer
      insertedCount?: integer
      updatedCount?: integer
      rejectedCount?: integer
      rejectPercent?: number
      rejectFilePath?: string
  Error:
    properties:
      code: string
      message: string
      correlationId: string
/runs:
  get:
    description: List import runs, newest first
    queryParameters:
      status?: string
      limit?: { type: integer, default: 20 }
    responses:
      200: { body: { type: Run[] } }
  /{runId}:
    get:
      responses:
        200: { body: { type: Run } }
        404: { body: { type: Error } }
    /rejects:
      get:
        responses:
          200:
            body:
              application/json:
                example: |
                  [{ "recordIndex": 5, "employeeId": "EMP10045", "rejectCode": "UNRESOLVED_DEPARTMENT", "rejectReason": "departmentCode DEPT-XXX not found" }]
/imports/reprocess:
  post:
    description: Re-trigger a file already in the inbound folder
    body:
      application/json:
        example: { "fileName": "EMP_IMPORT_20260911.csv" }
    responses:
      202: { body: { application/json: { example: { "runId": "RUN-1" } } } }
      400: { body: { type: Error } }
/health:
  get:
    responses:
      200: { body: { application/json: { example: { "status": "UP" } } } }
2.	Right-click the project > Mule > Generate Flows from Local REST API (APIkit). Studio creates the router and one flow per method. Rename flows to your naming standard, e.g. get:\runs:hr-import-config.
3.	Publish the RAML to Anypoint Design Center and Exchange so Auto Discovery can bind to it. In API Manager click Add API > Mule Gateway and copy the API ID.
4.	Add Auto Discovery in global-config.xml (shown in Step 5), using api.id from properties.
5.	For the System API, define /departments, /locations, /grades, /employees/{id} and /runs the same way and call them with HTTP requests from the Process API, or at minimum keep each as a private flow with a clear name.
Check: run the app and GET http://localhost:8081/api/v1/health returns { "status": "UP" }.
Step 5. Set up the Mule project, properties and global config
5.1 Add connectors and modules. In Studio, Mule Palette > Search in Exchange, add: File, Database, Email (SMTP), HTTP, APIkit, Object Store, Secure Configuration Properties, Validation, and the MUnit module. Add the MySQL driver to pom.xml:
<dependency>
  <groupId>com.mysql</groupId>
  <artifactId>mysql-connector-j</artifactId>
  <version>8.3.0</version>
</dependency>
5.2 Create config/app-config-dev.yaml (non-secret values):
app:
  file:
    inboundDir: "/data/hr/inbound"
    archiveDir: "/data/hr/archive"
    errorDir: "/data/hr/error"
    rejectDir: "/data/hr/reject"
    pollFrequencyMs: "10000"
  validation:
    minAge: "18"
    futureToleranceDays: "30"
    thresholdPercent: "40.00"
    duplicateStrategy: "UPDATE"   # INSERT_NEW | UPDATE | REJECT
    allowedEmploymentTypes: "PERMANENT,CONTRACT,INTERN,CONSULTANT"
  batch:
    size: "200"
    maxFailedRecords: "0"
  retry:
    maxAttempts: "3"
    delayMs: "2000"
  reject:
    sampleSize: "10"
db:
  host: "localhost"
  port: "3306"
  name: "hrdb"
  user: "hr_app"
smtp:
  host: "localhost"
  port: "1025"
  user: "hr-integration@company.com"
  from: "hr-integration@company.com"
hr:
  admin:
    distributionList: "hr-admin@company.com"
api:
  id: "0000000"
  autodiscovery:
    name: "groupId:{{orgId}}:assets:hr-employee-import-papi:1.0.0:minor"
http:
  port: "8081"
5.3 Create config/app-config-secure-dev.yaml (encrypted values). Encrypt each value with the Secure Properties Tool jar from MuleSoft docs:
java -cp secure-properties-tool.jar com.mulesoft.tools.SecurePropertiesTool \
  string encrypt Blowfish CBC MySecretKey123 "dbPassword"

db:
  password: "![x9Kq1ZpV0hYk3m2Q8d7a/w==]"
smtp:
  password: "![Lm4Rt8Ys2Bq9Xc6V1nPz0A==]"
The two strings above are mock values; replace them with your own encrypted output. Never commit the real key. Pass it at runtime as -M-Dmule.key=MySecretKey123 (Studio run configuration > Arguments), or as a property in Runtime Manager on CloudHub.
5.4 Create global-config.xml. It holds every shared configuration element:
<configuration-properties file="config/app-config-${mule.env}.yaml" />
<secure-properties:config name="Secure_Props" file="config/app-config-secure-${mule.env}.yaml" key="${mule.key}">
  <secure-properties:encrypt algorithm="Blowfish" mode="CBC" />
</secure-properties:config>

<http:listener-config name="HTTP_Listener_config">
  <http:listener-connection host="0.0.0.0" port="${http.port}" />
</http:listener-config>
<apikit:config name="hr-import-config" api="resource::...:hr-import-api.raml" outboundHeadersMapName="outboundHeaders" httpStatusVarName="httpStatus" />
<api-gateway:autodiscovery apiId="${api.id}" ignoreBasePath="true" flowRef="hr-import-main" />

<file:config name="File_Config"><file:connection workingDir="${app.file.inboundDir}" /></file:config>

<db:config name="Database_Config">
  <db:my-sql-connection host="${db.host}" port="${db.port}" user="${db.user}"
     password="${secure::db.password}" database="${db.name}" />
</db:config>

<email:smtp-config name="SMTP_Config">
  <email:smtp-connection host="${smtp.host}" port="${smtp.port}"
     user="${smtp.user}" password="${secure::smtp.password}" />
</email:smtp-config>

<os:object-store name="Processed_Files_Store" persistent="true" entryTtl="30" entryTtlUnit="DAYS" />
<ee:object-store-caching-strategy name="RefData_Cache" />
Notes:
•	Set mule.env=dev in mule-artifact.json or as a run argument -Dmule.env=dev; one config file per environment (dev, test, prod) is the pattern the brief means by "externalizing".
•	Never put a password in the plain yaml. Anything starting with smtp.password or db.password is read as ${secure::...}.
•	Domain project: create a Mule Domain Project hr-domain, move the three config elements (HTTP listener, DB, SMTP) into it, and set the app's Domain to it. This satisfies the "domain app for Studio runs" item.
•	Caching and object store: the reference data cache (departments, locations, grades) uses a <ee:cache> scope with RefData_Cache, and the Object Store keeps processed fileName|checksum pairs as a fast first check before the database check.
Step 6. Write the DataWeave modules
Build and test these in the DataWeave Playground or Studio's Transform preview with the sample files before touching any flow. Three files do the work; a small shared library keeps the CSV and XML output identical (that is how you pass acceptance criterion 1).
6.1 dwl/canonicalLib.dwl (shared cleaning and typing; avoid hyphens in module names):
%dw 2.0
import try, orElse from dw::Runtime

fun clean(v) = if (v == null) null else do {
    var t = trim(v as String)
    ---
    if (isEmpty(t)) null else t
}
fun up(v) = if (clean(v) == null) null else upper(clean(v))
fun low(v) = if (clean(v) == null) null else lower(clean(v))
fun toDate(v) = do {
    var s = clean(v)
    ---
    if (s == null) null
    else (try(() -> s as Date {format: "yyyy-MM-dd"}) orElse null)
}
fun toCanonical(r, idx) = {
    recordIndex: idx + 1,
    employeeId: up(r.employeeId),
    firstName: clean(r.firstName),
    lastName: clean(r.lastName),
    dateOfBirth: toDate(r.dateOfBirth),
    rawDateOfBirth: clean(r.dateOfBirth),
    dateOfJoining: toDate(r.dateOfJoining),
    rawDateOfJoining: clean(r.dateOfJoining),
    officialEmail: low(r.officialEmail),
    mobile: clean(r.mobile),
    departmentCode: up(r.departmentCode),
    designation: clean(r.designation),
    locationCode: up(r.locationCode),
    employmentType: up(r.employmentType),
    managerId: up(r.managerId)
}
6.2 dwl/csv-canonical-transform.dwl:
%dw 2.0
output application/java
import toCanonical from dwl::canonicalLib
var text = (payload as String {encoding: "UTF-8"}) replace "" with ""
var cleaned = ((text splitBy /\r?\n/) filter (!($ startsWith "#") and !isEmpty(trim($)))) joinBy "\n"
var rows = read(cleaned, "application/csv", { header: true })
---
rows map (r, idx) -> toCanonical(r, idx)
The script strips comment lines (starting with #), removes a byte-order mark, then reads the text as CSV with header=true, so each row is an object keyed by header name, never by position. That is what satisfies "do not map positionally by chance".
6.3 dwl/xml-canonical-transform.dwl:
%dw 2.0
output application/java
import toCanonical from dwl::canonicalLib
---
(payload.employeeImport.employees.*employee default []) map (e, idx) -> toCanonical(e, idx)
6.4 dwl/record-validation.dwl. Flow variables it expects: vars.cfg (minAge, futureToleranceDays, strategy, allowedTypes as array), and vars.refs built by the reference-load step: departments (object code to key), locations (code to key), grades (designation to grade), employees (existing employeeId to true), emails (existing email to employeeId).
%dw 2.0
output application/java
import isBlank from dw::core::Strings
import daysBetween from dw::core::Periods

var cfg     = vars.cfg
var depts   = vars.refs.departments
var locs    = vars.refs.locations
var grades  = vars.refs.grades
var dbEmp   = vars.refs.employees
var dbMail  = vars.refs.emails
var today   = now() as Date
var emailRx = /^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$/
var mobileRx = /^\+?[0-9][0-9\-\s]{7,18}[0-9]$/

var firstIdByEmp = payload filter (!isBlank($.employeeId default "")) groupBy $.employeeId
    mapObject ((v, k) -> { (k): v[0].recordIndex })
var firstIdByMail = payload filter (!isBlank($.officialEmail default "")) groupBy $.officialEmail
    mapObject ((v, k) -> { (k): v[0].employeeId })
var mgrOf = payload filter (!isBlank($.employeeId default "")) map ((r) -> { (r.employeeId): r.managerId })
    reduce ((o, acc = {}) -> acc ++ o)

fun miss(v, name) = if (isBlank((v as String) default "")) { code: "MISSING_FIELD", msg: "$(name) is missing" } else null
fun ageOn(dob: Date, d: Date) =
    d.year - dob.year - (if (d.month < dob.month or (d.month == dob.month and d.day < dob.day)) 1 else 0)
fun reachesSelf(cur, selfId, depth = 0) =
    if (cur == null or depth > 1000) false
    else if (cur == selfId) true
    else reachesSelf(mgrOf[cur], selfId, depth + 1)

fun baseErrors(r) = ([
    miss(r.employeeId, "employeeId"), miss(r.firstName, "firstName"), miss(r.lastName, "lastName"),
    miss(r.rawDateOfBirth, "dateOfBirth"), miss(r.rawDateOfJoining, "dateOfJoining"),
    miss(r.officialEmail, "officialEmail"), miss(r.departmentCode, "departmentCode"),
    miss(r.designation, "designation"), miss(r.locationCode, "locationCode"),
    miss(r.employmentType, "employmentType"),
    (if (r.rawDateOfBirth != null and r.dateOfBirth == null)
        { code: "INVALID_DATE", msg: "dateOfBirth is not a valid yyyy-MM-dd date" } else null),
    (if (r.rawDateOfJoining != null and r.dateOfJoining == null)
        { code: "INVALID_DATE", msg: "dateOfJoining is not a valid yyyy-MM-dd date" } else null),
    (if (r.officialEmail != null and !(r.officialEmail matches emailRx))
        { code: "INVALID_EMAIL", msg: "officialEmail format is invalid" } else null),
    (if (r.mobile != null and !(r.mobile matches mobileRx))
        { code: "INVALID_MOBILE", msg: "mobile format is invalid" } else null),
    (if (r.employmentType != null and !(cfg.allowedTypes contains r.employmentType))
        { code: "INVALID_EMPLOYMENT_TYPE", msg: "employmentType $(r.employmentType) is not supported" } else null),
    (if (r.dateOfBirth != null and ageOn(r.dateOfBirth, today) < cfg.minAge)
        { code: "UNDERAGE", msg: "age is below the minimum of $(cfg.minAge)" } else null),
    (if (r.dateOfJoining != null and daysBetween(today, r.dateOfJoining) > cfg.futureToleranceDays)
        { code: "FUTURE_JOINING_DATE", msg: "dateOfJoining is more than $(cfg.futureToleranceDays) days in the future" } else null),
    (if (r.departmentCode != null and depts[r.departmentCode] == null)
        { code: "UNRESOLVED_DEPARTMENT", msg: "departmentCode $(r.departmentCode) not found" } else null),
    (if (r.locationCode != null and locs[r.locationCode] == null)
        { code: "UNRESOLVED_LOCATION", msg: "locationCode $(r.locationCode) not found" } else null),
    (if (r.designation != null and grades[r.designation] == null)
        { code: "UNRESOLVED_DESIGNATION", msg: "designation $(r.designation) has no grade" } else null),
    (if (r.employeeId != null and firstIdByEmp[r.employeeId] != r.recordIndex)
        { code: "DUPLICATE_IN_FILE", msg: "employeeId $(r.employeeId) already appears at row $(firstIdByEmp[r.employeeId])" }
     else if (r.employeeId != null and (cfg.strategy == "REJECT" or cfg.strategy == "INSERT_NEW") and dbEmp[r.employeeId] != null)
        { code: "DUPLICATE_IN_DB", msg: "employeeId $(r.employeeId) already exists and strategy is $(cfg.strategy)" } else null),
    (if (r.officialEmail != null and firstIdByMail[r.officialEmail] != r.employeeId)
        { code: "DUPLICATE_EMAIL", msg: "officialEmail already used by $(firstIdByMail[r.officialEmail]) in this file" }
     else if (r.officialEmail != null and dbMail[r.officialEmail] != null and dbMail[r.officialEmail] != r.employeeId)
        { code: "DUPLICATE_EMAIL", msg: "officialEmail already belongs to $(dbMail[r.officialEmail])" } else null),
    (if (r.managerId != null and reachesSelf(r.managerId, r.employeeId))
        { code: "CIRCULAR_MANAGER", msg: "managerId $(r.managerId) creates a circular or self reporting line" } else null)
] filter ($ != null))

var stage1 = payload map ((r) -> r ++ { errs: baseErrors(r) })

// Fixpoint: a manager inside the file counts only if that manager is itself accepted.
fun settle(okSet, recs) = do {
    var bad = recs filter ((r) -> okSet[r.employeeId] == true and r.managerId != null
        and dbEmp[r.managerId] == null and okSet[r.managerId] == null)
    ---
    if (isEmpty(bad)) okSet
    else settle(okSet filterObject ((v, k) -> !(bad.employeeId contains (k as String))), recs)
}
var okSet0 = { (stage1 filter (isEmpty($.errs)) map ((r) -> { (r.employeeId): true })) }
var okSet  = settle(okSet0, stage1)
---
stage1 map ((r) -> do {
    var mgrErr = if (r.managerId != null and dbEmp[r.managerId] == null and okSet[r.managerId] == null
                     and isEmpty(r.errs))
        [{ code: "UNRESOLVED_MANAGER", msg: "managerId $(r.managerId) not found in file or database" }]
        else []
    var allErrs = r.errs ++ mgrErr
    var isReject = !isEmpty(allErrs)
    ---
    (r - "errs") ++ {
        action: if (isReject) "REJECT" else if (dbEmp[r.employeeId] != null) "UPDATE" else "INSERT",
        strategyApplied: if (isReject) "REJECT" else if (dbEmp[r.employeeId] != null) cfg.strategy else "INSERT_NEW",
        rejectCode: allErrs[0].code,
        rejectReason: allErrs.msg joinBy "; ",
        departmentKey: depts[r.departmentCode],
        locationKey: locs[r.locationCode],
        grade: grades[r.designation],
        managerKey: r.managerId
    }
})
Things to know before you test it:
•	Each output record has action (INSERT, UPDATE, REJECT), the first rejectCode, and rejectReason listing every problem for that row.
•	Strategy values: UPDATE overwrites existing rows; INSERT_NEW and REJECT both reject a row whose ID already exists in the database, with the strategy name in the message. Keep all three values to show the configurable behaviour the brief asks for.
•	When strategy is UPDATE, a later in-file duplicate is still rejected so two rows are never created for one ID.
•	Run it in the Playground first with a handcrafted vars.refs; fix syntax issues there rather than inside Studio. If your runtime rejects a function used above (for example daysBetween), replace it with (r.dateOfJoining - today).days-style math or a dw::core::Dates helper.
•	The module logs nothing, and no error message contains a date of birth, mobile number or compensation value, so it is privacy-safe.
Step 7. Build the flows (intake to email)
Build the flows in the order below, running the app after each one. Snippets show the Mule XML you will see in the Configuration XML tab; in Studio you can drag the same components and Studio adds the doc:id attributes for you. Use these naming patterns everywhere (standard names are an explicit requirement): hr-import-<purpose>-flow, hr-import-<purpose>-subflow, and descriptive doc:name on every component.
7.0 Two small changes first.
ALTER TABLE employee_import_runs ADD COLUMN failure_reason VARCHAR(255) NULL;
In global-config.xml make two edits to Step 5: change the file connection to <file:connection /> (so absolute paths from the properties work for read, write and move), and add the cache pieces:
<file:matcher name="Import_Files_Matcher" filenamePattern="*.{csv,xml,CSV,XML}" />
<os:object-store name="RefData_OS" persistent="false" entryTtl="10" entryTtlUnit="MINUTES" />
<ee:object-store-caching-strategy name="RefData_Cache" objectStore="RefData_OS" keyGenerationExpression="#['refdata']" />
Also add <reconnection><reconnect frequency="${app.retry.delayMs}" count="${app.retry.maxAttempts}" /></reconnection> inside the db:my-sql-connection and email:smtp-connection elements; this is the retry for transient DB and SMTP errors.
7.1 main-flow.xml: file intake and routing
<flow name="hr-import-main-flow">
  <file:listener config-ref="File_Config" directory="${app.file.inboundDir}" autoDelete="false"
      matcher="Import_Files_Matcher" timeBetweenSizeCheck="2" timeBetweenSizeCheckUnit="SECONDS">
    <scheduling-strategy><fixed-frequency frequency="${app.file.pollFrequencyMs}" /></scheduling-strategy>
  </file:listener>
  <flow-ref name="hr-import-init-subflow" />
  <flow-ref name="hr-import-duplicate-check-subflow" />
  <choice>
    <when expression="#[vars.isDuplicate]">
      <set-variable variableName="finalStatus" value="DUPLICATE_FILE" />
      <set-variable variableName="targetDir" value="${app.file.archiveDir}" />
      <flow-ref name="hr-import-finalize-subflow" />
    </when>
    <when expression="#[vars.fileSize == 0]">
      <set-variable variableName="finalStatus" value="EMPTY" />
      <set-variable variableName="targetDir" value="${app.file.archiveDir}" />
      <flow-ref name="hr-import-finalize-subflow" />
    </when>
    <otherwise>
      <choice>
        <when expression="#[vars.fileFormat == 'CSV']"><flow-ref name="hr-import-parse-csv-subflow" /></when>
        <when expression="#[vars.fileFormat == 'XML']"><flow-ref name="hr-import-parse-xml-subflow" /></when>
        <otherwise><raise-error type="HR:INVALID_FILE" description="Unsupported file type" /></otherwise>
      </choice>
      <flow-ref name="hr-import-load-refdata-subflow" />
      <flow-ref name="hr-import-validate-records-subflow" />
      <flow-ref name="hr-import-threshold-check-subflow" />
    </otherwise>
  </choice>
  <error-handler ref="global-error-handler" />
</flow>
7.2 hr-import-init-subflow: set the identifiers, detect the format and compute the checksum. The checksum and size use the raw bytes, so do them before any parsing.
<sub-flow name="hr-import-init-subflow">
  <set-variable variableName="fileName"   value="#[attributes.fileName]" />
  <set-variable variableName="sourcePath" value="#[attributes.path]" />
  <set-variable variableName="runId"      value="#['RUN-' ++ (now() as String {format: 'yyyyMMddHHmmss'}) ++ '-' ++ uuid()[0 to 7]]" />
  <set-variable variableName="startedAt"  value="#[now()]" />
  <set-variable variableName="rawFile"    value="#[payload]" />
  <set-variable variableName="fileSize"   value="#[sizeOf(payload as Binary)]" />
  <set-variable variableName="checksum"   value="#[dw::core::Binaries::toHex(dw::Crypto::hashWith(payload as Binary, 'SHA-256'))]" />
  <set-variable variableName="fileFormat"
      value="#[if (upper(vars.fileName) endsWith '.CSV') 'CSV' else if (upper(vars.fileName) endsWith '.XML') 'XML' else if (vars.fileSize > 0 and (payload as String)[0 to 0] == '&lt;') 'XML' else 'CSV']" />
  <set-variable variableName="isDuplicate" value="#[false]" />
  <logger level="INFO" category="hr.import"
      message="#['runId=' ++ vars.runId ++ ' file=' ++ vars.fileName ++ ' format=' ++ vars.fileFormat ++ ' event=FILE_PICKED_UP']" />
</sub-flow>
7.3 hr-import-duplicate-check-subflow (duplicate file submission). It checks the Object Store first, then the database; then registers the run.
<sub-flow name="hr-import-duplicate-check-subflow">
  <db:select config-ref="Database_Config">
    <db:sql>SELECT run_status FROM employee_import_runs WHERE file_name = :f AND file_checksum = :c</db:sql>
    <db:input-parameters>#[{ f: vars.fileName, c: vars.checksum }]</db:input-parameters>
  </db:select>
  <set-variable variableName="isDuplicate"
      value="#[sizeOf(payload filter (['SUCCESS','PARTIAL','EMPTY','ABORTED','FAILED'] contains upper($.run_status))) > 0]" />
  <choice>
    <when expression="#[!vars.isDuplicate]">
      <db:insert config-ref="Database_Config">
        <db:sql>INSERT INTO employee_import_runs (run_id, file_name, file_format, file_checksum, run_status, started_at, correlation_id)
                VALUES (:runId, :f, :fmt, :c, 'RUNNING', NOW(), :corr)</db:sql>
        <db:input-parameters>#[{ runId: vars.runId, f: vars.fileName, fmt: vars.fileFormat, c: vars.checksum, corr: correlationId }]</db:input-parameters>
      </db:insert>
    </when>
  </choice>
</sub-flow>
Because (file_name, file_checksum) is unique, a second concurrent insert fails and is treated as a duplicate by the error handler. Decide whether a FAILED run should be blocked as duplicate; the list above blocks it. To allow a retry of an unchanged failed file, remove 'FAILED' and delete that run's row first.
7.4 parse-flows.xml: file-level validation and canonical transform. Both subflows leave the same variables: vars.records (canonical array), vars.declaredCount and vars.sourceSystem.
<sub-flow name="hr-import-parse-csv-subflow">
  <ee:transform doc:name="CSV file-level check">
    <ee:message><ee:set-payload><![CDATA[%dw 2.0
output application/java
var expected = ["employeeId","firstName","lastName","dateOfBirth","dateOfJoining","officialEmail",
                "mobile","departmentCode","designation","locationCode","employmentType","managerId"]
var text   = payload as String {encoding: "UTF-8"}
var lines  = (text splitBy /\r?\n/) filter (!isEmpty(trim($)))
var data   = lines filter (!($ startsWith "#"))
var header = ((data[0] default "") replace "" with "") splitBy "," map trim($)
var decl   = (lines filter ($ startsWith "#recordCount="))[0]
---
{
  error: if (text contains "�") "File encoding is not valid UTF-8"
         else if (isEmpty(data)) "File has no header row"
         else if (header != expected) "CSV header is missing, reordered or has unexpected columns: expected " ++ (expected joinBy ",")
         else null,
  declared: if (decl == null) null else ((decl splitBy "=")[1] as Number)
}]]></ee:set-payload></ee:message>
    <ee:variables><ee:set-variable variableName="fileCheck">#[payload]</ee:set-variable></ee:variables>
  </ee:transform>
  <choice>
    <when expression="#[vars.fileCheck.error != null]">
      <raise-error type="HR:INVALID_FILE" description="#[vars.fileCheck.error]" />
    </when>
  </choice>
  <try>
    <set-payload value="#[vars.rawFile]" />
    <ee:transform doc:name="CSV to canonical">
      <ee:message><ee:set-payload resource="dwl/csv-canonical-transform.dwl" /></ee:message>
    </ee:transform>
    <error-handler>
      <on-error-propagate type="MULE:EXPRESSION">
        <raise-error type="HR:INVALID_FILE" description="CSV body cannot be parsed" />
      </on-error-propagate>
    </error-handler>
  </try>
  <set-variable variableName="records"       value="#[payload]" />
  <set-variable variableName="declaredCount" value="#[vars.fileCheck.declared]" />
  <set-variable variableName="sourceSystem"  value="#['n/a']" />
  <flow-ref name="hr-import-count-check-subflow" />
</sub-flow>
The file-level check only fills the fileCheck variable and the payload is restored from rawFile before the canonical transform, so both steps read the original bytes. A CSV may carry an optional trailer line such as #recordCount=5 to declare its count; XML declares it in the header element.
<sub-flow name="hr-import-parse-xml-subflow">
  <try>
    <ee:transform doc:name="XML file-level check">
      <ee:message><ee:set-payload><![CDATA[%dw 2.0
output application/java
var expected = ["employeeId","firstName","lastName","dateOfBirth","dateOfJoining","officialEmail",
                "mobile","departmentCode","designation","locationCode","employmentType","managerId"]
var root = payload.employeeImport
var emps = root.employees.*employee default []
var missing = emps map ((e, i) -> { row: i + 1, gone: expected -- (keysOf(e) map ($ as String)) })
              filter (!isEmpty($.gone))
---
{
  error: if (root == null) "Root element employeeImport is missing"
         else if (root.employees == null) "Element employees is missing"
         else if (!isEmpty(missing)) "Employee element(s) missing required elements, first at row " ++ missing[0].row ++ ": " ++ (missing[0].gone joinBy ",")
         else null,
  declared: root.header.recordCount as Number default null,
  sourceSystem: root.header.sourceSystem as String default "n/a"
}]]></ee:set-payload></ee:message>
      <ee:variables><ee:set-variable variableName="fileCheck">#[payload]</ee:set-variable></ee:variables>
    </ee:transform>
    <error-handler>
      <on-error-propagate type="MULE:EXPRESSION">
        <raise-error type="HR:INVALID_FILE" description="XML cannot be parsed" />
      </on-error-propagate>
    </error-handler>
  </try>
  <choice>
    <when expression="#[vars.fileCheck.error != null]">
      <raise-error type="HR:INVALID_FILE" description="#[vars.fileCheck.error]" />
    </when>
  </choice>
  <set-payload value="#[vars.rawFile]" />
  <ee:transform doc:name="XML to canonical">
    <ee:message><ee:set-payload resource="dwl/xml-canonical-transform.dwl" /></ee:message>
  </ee:transform>
  <set-variable variableName="records"       value="#[payload]" />
  <set-variable variableName="declaredCount" value="#[vars.fileCheck.declared]" />
  <set-variable variableName="sourceSystem"  value="#[vars.fileCheck.sourceSystem]" />
  <flow-ref name="hr-import-count-check-subflow" />
</sub-flow>

<sub-flow name="hr-import-count-check-subflow">
  <choice>
    <when expression="#[vars.declaredCount != null and vars.declaredCount != sizeOf(vars.records)]">
      <raise-error type="HR:COUNT_MISMATCH"
          description="#['Declared ' ++ vars.declaredCount ++ ' records but parsed ' ++ sizeOf(vars.records)]" />
    </when>
  </choice>
</sub-flow>
In the XML flow the try around the check also catches a broken XML body, because the first access to payload.employeeImport forces the parse. For an empty record list (header present but no rows) the run ends as EMPTY: add a <choice> after the count check that sets finalStatus to EMPTY and calls hr-import-finalize-subflow when sizeOf(vars.records) == 0, then stops using an on-error or by wrapping the rest of the main flow in the otherwise branch.
7.5 hr-import-load-refdata-subflow (reference data with caching). Masters are cached for 10 minutes; employees and emails are read fresh because they change on every run.
<sub-flow name="hr-import-load-refdata-subflow">
  <set-payload value="REFDATA" />
  <ee:cache cachingStrategy-ref="RefData_Cache">
    <db:select config-ref="Database_Config"><db:sql>SELECT department_code, department_key FROM department_master WHERE is_active = TRUE</db:sql></db:select>
    <set-variable variableName="deptRows" value="#[payload]" />
    <db:select config-ref="Database_Config"><db:sql>SELECT location_code, location_key FROM location_master WHERE is_active = TRUE</db:sql></db:select>
    <set-variable variableName="locRows" value="#[payload]" />
    <db:select config-ref="Database_Config"><db:sql>SELECT designation, grade FROM designation_grade_master</db:sql></db:select>
    <ee:transform>
      <ee:message><ee:set-payload><![CDATA[%dw 2.0
output application/java
---
{
  departments: { (vars.deptRows map ((r) -> { (r.department_code): r.department_key })) },
  locations:   { (vars.locRows  map ((r) -> { (r.location_code):   r.location_key  })) },
  grades:      { (payload       map ((r) -> { (r.designation):     r.grade         })) }
}]]></ee:set-payload></ee:message>
    </ee:transform>
  </ee:cache>
  <set-variable variableName="refsStatic" value="#[payload]" />
  <db:select config-ref="Database_Config"><db:sql>SELECT employee_id, official_email FROM employees</db:sql></db:select>
  <ee:transform>
    <ee:message><ee:set-payload><![CDATA[%dw 2.0
output application/java
---
vars.refsStatic ++ {
  employees: { (payload map ((r) -> { (r.employee_id): true })) },
  emails:    { (payload map ((r) -> { (lower(r.official_email)): r.employee_id })) }
}]]></ee:set-payload></ee:message>
    <ee:variables><ee:set-variable variableName="refs">#[payload]</ee:set-variable></ee:variables>
  </ee:transform>
</sub-flow>
For a very large employee table replace the last query with a staging-table join (load file IDs and emails into a temp table, then select the matches) so you do not pull the whole table. For the hackathon the full read is fine.
7.6 hr-import-validate-records-subflow and hr-import-threshold-check-subflow
<sub-flow name="hr-import-validate-records-subflow">
  <set-variable variableName="cfg"
      value="#[{ minAge: p('app.validation.minAge') as Number,
                 futureToleranceDays: p('app.validation.futureToleranceDays') as Number,
                 strategy: p('app.validation.duplicateStrategy'),
                 allowedTypes: p('app.validation.allowedEmploymentTypes') splitBy ',' }]" />
  <set-payload value="#[vars.records]" />
  <ee:transform doc:name="Validate and tag records">
    <ee:message><ee:set-payload resource="dwl/record-validation.dwl" /></ee:message>
  </ee:transform>
  <set-variable variableName="validated" value="#[payload]" />
  <ee:transform doc:name="Build summary">
    <ee:message><ee:set-payload><![CDATA[%dw 2.0
output application/java
var rej = payload filter ($.action == "REJECT")
var total = sizeOf(payload)
---
{
  total: total,
  rejected: sizeOf(rej),
  inserted: sizeOf(payload filter ($.action == "INSERT")),
  updated:  sizeOf(payload filter ($.action == "UPDATE")),
  rejectPercent: if (total == 0) 0 else round((sizeOf(rej) / total) * 10000) / 100,
  rejectSummary: (rej groupBy $.rejectCode) pluck ((v, k) -> { rejectCode: k as String, count: sizeOf(v) })
}]]></ee:set-payload></ee:message>
    <ee:variables><ee:set-variable variableName="summary">#[payload]</ee:set-variable></ee:variables>
  </ee:transform>
  <logger level="INFO" category="hr.import"
      message="#['runId=' ++ vars.runId ++ ' event=VALIDATED total=' ++ vars.summary.total ++ ' rejected=' ++ vars.summary.rejected ++ ' pct=' ++ vars.summary.rejectPercent]" />
</sub-flow>

<sub-flow name="hr-import-threshold-check-subflow">
  <choice>
    <when expression="#[vars.summary.rejectPercent > (p('app.validation.thresholdPercent') as Number)]">
      <logger level="ERROR" category="hr.import.alert"
          message="#['ALERT runId=' ++ vars.runId ++ ' event=THRESHOLD_EXCEEDED pct=' ++ vars.summary.rejectPercent]" />
      <set-variable variableName="finalStatus" value="ABORTED" />
      <set-variable variableName="failureReason"
          value="#['Rejection rate ' ++ vars.summary.rejectPercent ++ '% exceeds the ' ++ p('app.validation.thresholdPercent') ++ '% limit. The file appears to be the wrong extract; no records were written.']" />
      <flow-ref name="hr-import-write-rejects-subflow" />
      <set-variable variableName="targetDir" value="${app.file.errorDir}" />
      <flow-ref name="hr-import-finalize-subflow" />
    </when>
    <otherwise>
      <flow-ref name="hr-import-persist-flow" />
    </otherwise>
  </choice>
</sub-flow>
The abort writes nothing to employees: the abort branch never calls the persistence flow. The ABORTED status is shown to HR as a FAILED email (see 7.8).
7.7 persistence-flow.xml: reject output first, then the two-pass batch write
Order matters. The rejects are already known after validation, so write them (table and reject file) before the batch starts. The batch's on-complete phase then only needs counts and IDs, never personal data. Add one more store to global-config.xml:
<os:object-store name="Run_Context_Store" persistent="true" entryTtl="1" entryTtlUnit="DAYS" />

<sub-flow name="hr-import-write-rejects-subflow">
  <set-variable variableName="rejects" value="#[vars.validated filter ($.action == 'REJECT')]" />
  <set-variable variableName="rejectSample"
      value="#[vars.rejects[0 to (p('app.reject.sampleSize') as Number) - 1] map { recordIndex: $.recordIndex, employeeId: $.employeeId, rejectReason: $.rejectReason }]" />
  <choice>
    <when expression="#[sizeOf(vars.rejects) > 0]">
      <ee:transform doc:name="Rejects for table">
        <ee:message><ee:set-payload><![CDATA[%dw 2.0
output application/java
---
vars.rejects map ((r) -> {
  runId: vars.runId, recordIndex: r.recordIndex, employeeId: r.employeeId,
  rejectCode: r.rejectCode, rejectReason: (r.rejectReason default "")[0 to 254]
})]]></ee:set-payload></ee:message>
      </ee:transform>
      <db:bulk-insert config-ref="Database_Config">
        <db:sql>INSERT INTO employee_import_rejects (run_id, record_index, employee_id, reject_code, reject_reason)
                VALUES (:runId, :recordIndex, :employeeId, :rejectCode, :rejectReason)</db:sql>
      </db:bulk-insert>
      <choice>
        <when expression="#[vars.fileFormat == 'CSV']">
          <ee:transform doc:name="Reject CSV"><ee:message><ee:set-payload resource="dwl/reject-csv.dwl" /></ee:message></ee:transform>
        </when>
        <otherwise>
          <ee:transform doc:name="Reject XML"><ee:message><ee:set-payload resource="dwl/reject-xml.dwl" /></ee:message></ee:transform>
        </otherwise>
      </choice>
      <set-variable variableName="rejectFilePath"
          value="#[p('app.file.rejectDir') ++ '/REJECT_' ++ vars.fileName]" />
      <file:write config-ref="File_Config" path="#[vars.rejectFilePath]" createParentDirectories="true" mode="OVERWRITE" />
    </when>
  </choice>
</sub-flow>
The bulk-insert with no explicit input parameters uses the payload array, so each map key must match a :name in the SQL.
dwl/reject-csv.dwl (same columns and order as the input, plus rejectReason; raw date text is used so an unparseable date comes back exactly as received):
%dw 2.0
output application/csv header=true, quoteValues=true
---
vars.rejects map ((r) -> {
  employeeId: r.employeeId default "", firstName: r.firstName default "", lastName: r.lastName default "",
  dateOfBirth: r.rawDateOfBirth default "", dateOfJoining: r.rawDateOfJoining default "",
  officialEmail: r.officialEmail default "", mobile: r.mobile default "",
  departmentCode: r.departmentCode default "", designation: r.designation default "",
  locationCode: r.locationCode default "", employmentType: r.employmentType default "",
  managerId: r.managerId default "",
  rejectReason: (r.rejectCode default "") ++ ": " ++ (r.rejectReason default "")
})
dwl/reject-xml.dwl:
%dw 2.0
output application/xml indent=true
---
employeeImport: {
  header: {
    sourceSystem: vars.sourceSystem default "n/a",
    generatedAt: now(),
    recordCount: sizeOf(vars.rejects)
  },
  employees: {
    (vars.rejects map ((r) -> employee: {
      employeeId: r.employeeId default "", firstName: r.firstName default "", lastName: r.lastName default "",
      dateOfBirth: r.rawDateOfBirth default "", dateOfJoining: r.rawDateOfJoining default "",
      officialEmail: r.officialEmail default "", mobile: r.mobile default "",
      departmentCode: r.departmentCode default "", designation: r.designation default "",
      locationCode: r.locationCode default "", employmentType: r.employmentType default "",
      managerId: r.managerId default "",
      rejectReason: (r.rejectCode default "") ++ ": " ++ (r.rejectReason default "")
    }))
  }
}
Now the batch. Pass 1 upserts every accepted employee with manager_key = NULL (so a manager appearing later in the file cannot break a foreign key). Pass 2 sets the manager link after every row exists. This is the forward-reference requirement.
<flow name="hr-import-persist-flow">
  <flow-ref name="hr-import-write-rejects-subflow" />
  <os:store key="#[vars.runId]" objectStore="Run_Context_Store">
    <os:value><![CDATA[#[{
      runId: vars.runId, fileName: vars.fileName, fileFormat: vars.fileFormat, sourceSystem: vars.sourceSystem,
      sourcePath: vars.sourcePath, startedAt: vars.startedAt, declaredCount: vars.declaredCount,
      summary: vars.summary, rejectSample: vars.rejectSample, rejectFilePath: vars.rejectFilePath,
      insertIds: (vars.validated filter ($.action == 'INSERT')).employeeId,
      updateIds: (vars.validated filter ($.action == 'UPDATE')).employeeId,
      managerLinks: vars.validated filter ($.action != 'REJECT' and $.managerKey != null)
                    map { employeeId: $.employeeId, managerKey: $.managerKey }
    }]]]></os:value>
  </os:store>
  <set-payload value="#[vars.validated filter ($.action != 'REJECT') map ($ ++ { runId: vars.runId })]" />

  <batch:job jobName="hr-import-batch-job" blockSize="${app.batch.size}" maxFailedRecords="-1">
    <batch:process-records>
      <batch:step name="hr-import-upsert-step">
        <batch:aggregator size="${app.batch.size}">
          <try>
            <try transactionalAction="ALWAYS_BEGIN">
              <flow-ref name="hr-import-upsert-bulk-subflow" />
            </try>
            <error-handler>
              <on-error-continue type="ANY">
                <logger level="WARN" category="hr.import"
                    message="#['runId=' ++ vars.runId ++ ' event=BATCH_ROLLED_BACK size=' ++ sizeOf(payload) ++ ' errorType=' ++ error.errorType.identifier]" />
                <foreach>
                  <try transactionalAction="ALWAYS_BEGIN">
                    <flow-ref name="hr-import-upsert-one-subflow" />
                    <error-handler>
                      <on-error-continue type="ANY">
                        <flow-ref name="hr-import-record-db-error-subflow" />
                      </on-error-continue>
                    </error-handler>
                  </try>
                </foreach>
              </on-error-continue>
            </error-handler>
          </try>
          <logger level="INFO" category="hr.import" message="#['runId=' ++ vars.runId ++ ' event=BATCH_COMMITTED size=' ++ sizeOf(payload)]" />
          <db:update config-ref="Database_Config">
            <db:sql>UPDATE employee_import_runs SET batches_completed = batches_completed + 1 WHERE run_id = :runId</db:sql>
            <db:input-parameters>#[{ runId: vars.runId }]</db:input-parameters>
          </db:update>
        </batch:aggregator>
      </batch:step>
    </batch:process-records>
    <batch:on-complete>
      <flow-ref name="hr-import-restore-context-subflow" />
      <flow-ref name="hr-import-pass2-managers-subflow" />
      <flow-ref name="hr-import-final-counts-subflow" />
      <flow-ref name="hr-import-finalize-subflow" />
    </batch:on-complete>
  </batch:job>
</flow>
The three small subflows used above:
<sub-flow name="hr-import-upsert-bulk-subflow">
  <db:bulk-insert config-ref="Database_Config">
    <db:sql><![CDATA[INSERT INTO employees (employee_id, first_name, last_name, date_of_birth, date_of_joining,
  official_email, mobile, department_key, designation, grade, location_key, employment_type,
  manager_key, employee_status, source_run_id)
VALUES (:employeeId, :firstName, :lastName, :dateOfBirth, :dateOfJoining, :officialEmail, :mobile,
  :departmentKey, :designation, :grade, :locationKey, :employmentType, NULL, 'ACTIVE', :runId)
ON DUPLICATE KEY UPDATE first_name = VALUES(first_name), last_name = VALUES(last_name),
  date_of_birth = VALUES(date_of_birth), date_of_joining = VALUES(date_of_joining),
  official_email = VALUES(official_email), mobile = VALUES(mobile),
  department_key = VALUES(department_key), designation = VALUES(designation), grade = VALUES(grade),
  location_key = VALUES(location_key), employment_type = VALUES(employment_type),
  manager_key = NULL, source_run_id = VALUES(source_run_id), updated_at = CURRENT_TIMESTAMP]]></db:sql>
  </db:bulk-insert>
</sub-flow>

<sub-flow name="hr-import-upsert-one-subflow">
  <db:insert config-ref="Database_Config">
    <!-- same SQL text as the bulk subflow -->
    <db:sql><![CDATA[INSERT INTO employees (employee_id, first_name, last_name, date_of_birth, date_of_joining,
  official_email, mobile, department_key, designation, grade, location_key, employment_type,
  manager_key, employee_status, source_run_id)
VALUES (:employeeId, :firstName, :lastName, :dateOfBirth, :dateOfJoining, :officialEmail, :mobile,
  :departmentKey, :designation, :grade, :locationKey, :employmentType, NULL, 'ACTIVE', :runId)
ON DUPLICATE KEY UPDATE first_name = VALUES(first_name), last_name = VALUES(last_name),
  date_of_birth = VALUES(date_of_birth), date_of_joining = VALUES(date_of_joining),
  official_email = VALUES(official_email), mobile = VALUES(mobile),
  department_key = VALUES(department_key), designation = VALUES(designation), grade = VALUES(grade),
  location_key = VALUES(location_key), employment_type = VALUES(employment_type),
  manager_key = NULL, source_run_id = VALUES(source_run_id), updated_at = CURRENT_TIMESTAMP]]></db:sql>
    <db:input-parameters>#[payload]</db:input-parameters>
  </db:insert>
</sub-flow>

<sub-flow name="hr-import-record-db-error-subflow">
  <db:insert config-ref="Database_Config">
    <db:sql>INSERT INTO employee_import_rejects (run_id, record_index, employee_id, reject_code, reject_reason)
            VALUES (:runId, :recordIndex, :employeeId, 'DB_ERROR', 'Record could not be written after the batch was rolled back')</db:sql>
    <db:input-parameters>#[{ runId: vars.runId, recordIndex: payload.recordIndex, employeeId: payload.employeeId }]</db:input-parameters>
  </db:insert>
</sub-flow>
How the all-or-nothing rule is met: the 200-record transaction either commits whole or rolls back whole (no half-written batch, no double count). If it rolls back, each record is retried alone in its own transaction, and only the record that really fails becomes a DB_ERROR reject. Inside the foreach, payload is the single record, which is why the error subflow reads payload.recordIndex.
Two cautions. The upsert statement also fires on the unique email key, so the email-duplicate check in validation must stay (a race between two simultaneous runs is the only remaining gap). And Studio may show ${app.batch.size} as a string in blockSize; if it complains use a plain number in that one attribute.
On-complete subflows (pass 2, counts, restore):
<sub-flow name="hr-import-restore-context-subflow">
  <os:retrieve key="#[vars.runId]" objectStore="Run_Context_Store" target="ctx" />
  <set-variable variableName="fileName"      value="#[vars.ctx.fileName]" />
  <set-variable variableName="fileFormat"    value="#[vars.ctx.fileFormat]" />
  <set-variable variableName="sourceSystem"  value="#[vars.ctx.sourceSystem]" />
  <set-variable variableName="sourcePath"    value="#[vars.ctx.sourcePath]" />
  <set-variable variableName="startedAt"     value="#[vars.ctx.startedAt]" />
  <set-variable variableName="declaredCount" value="#[vars.ctx.declaredCount]" />
  <set-variable variableName="summary"       value="#[vars.ctx.summary]" />
  <set-variable variableName="rejectSample"  value="#[vars.ctx.rejectSample]" />
  <set-variable variableName="rejectFilePath" value="#[vars.ctx.rejectFilePath]" />
  <db:select config-ref="Database_Config">
    <db:sql>SELECT employee_id FROM employee_import_rejects WHERE run_id = :runId AND reject_code = 'DB_ERROR'</db:sql>
    <db:input-parameters>#[{ runId: vars.runId }]</db:input-parameters>
  </db:select>
  <set-variable variableName="dbErrorIds" value="#[payload map $.employee_id]" />
</sub-flow>

<sub-flow name="hr-import-pass2-managers-subflow">
  <set-payload value="#[vars.ctx.managerLinks filter (!(vars.dbErrorIds contains $.employeeId)) map ($ ++ { runId: vars.runId })]" />
  <foreach batchSize="${app.batch.size}">
    <try transactionalAction="ALWAYS_BEGIN">
      <db:bulk-update config-ref="Database_Config">
        <db:sql>UPDATE employees SET manager_key = :managerKey WHERE employee_id = :employeeId AND source_run_id = :runId</db:sql>
      </db:bulk-update>
    </try>
  </foreach>
</sub-flow>

<sub-flow name="hr-import-final-counts-subflow">
  <ee:transform>
    <ee:message><ee:set-payload><![CDATA[%dw 2.0
output application/java
var inserted = vars.ctx.insertIds -- vars.dbErrorIds
var updated  = vars.ctx.updateIds -- vars.dbErrorIds
var rejected = vars.ctx.summary.rejected + sizeOf(vars.dbErrorIds)
var total    = vars.ctx.summary.total
---
{
  total: total, rejected: rejected,
  inserted: sizeOf(inserted), updated: sizeOf(updated),
  rejectPercent: if (total == 0) 0 else round((rejected / total) * 10000) / 100,
  rejectSummary: vars.ctx.summary.rejectSummary ++ (if (isEmpty(vars.dbErrorIds)) [] else [{ rejectCode: "DB_ERROR", count: sizeOf(vars.dbErrorIds) }])
}]]></ee:set-payload></ee:message>
    <ee:variables><ee:set-variable variableName="summary">#[payload]</ee:set-variable></ee:variables>
  </ee:transform>
  <set-variable variableName="finalStatus"
      value="#[if (vars.summary.rejected == 0) 'SUCCESS' else if (vars.summary.inserted + vars.summary.updated == 0) 'FAILED' else 'PARTIAL']" />
  <set-variable variableName="targetDir"
      value="#[if (vars.finalStatus == 'FAILED') p('app.file.errorDir') else p('app.file.archiveDir')]" />
</sub-flow>
The on-complete phase relies on vars.runId being visible there (variables set before the batch job are copied into it). If your runtime does not do that, store the current run ID under a fixed key such as current-run in the same object store before the batch and read it first in hr-import-restore-context-subflow; since the listener handles one file at a time, that is safe.
7.8 notification-flow.xml: the single finalize point. Every ending (success, partial, aborted, duplicate, empty, failed) calls this subflow after setting finalStatus, targetDir, and optionally failureReason. It updates the audit row, sends the email, and moves the file.
<sub-flow name="hr-import-finalize-subflow">
  <ee:transform doc:name="Build final summary">
    <ee:message><ee:set-payload><![CDATA[%dw 2.0
output application/java
---
{
  status: vars.finalStatus, runId: vars.runId, fileName: vars.fileName, fileFormat: vars.fileFormat default "n/a",
  sourceSystem: vars.sourceSystem default "n/a", startedAt: vars.startedAt, completedAt: now(),
  declared: vars.declaredCount, parsed: vars.summary.total default 0,
  inserted: vars.summary.inserted default 0, updated: vars.summary.updated default 0,
  rejected: vars.summary.rejected default 0, rejectPercent: vars.summary.rejectPercent default 0,
  rejectSummary: vars.summary.rejectSummary default [], rejectSample: vars.rejectSample default [],
  rejectFilePath: vars.rejectFilePath default "none", failureReason: vars.failureReason default null
}]]></ee:set-payload></ee:message>
    <ee:variables><ee:set-variable variableName="final">#[payload]</ee:set-variable></ee:variables>
  </ee:transform>
  <choice>
    <when expression="#[vars.finalStatus != 'DUPLICATE_FILE']">
      <db:update config-ref="Database_Config">
        <db:sql>UPDATE employee_import_runs SET run_status = :status, declared_count = :declared, parsed_count = :parsed,
                inserted_count = :ins, updated_count = :upd, rejected_count = :rej, reject_percent = :pct,
                reject_file_path = :rfp, failure_reason = :reason, completed_at = NOW() WHERE run_id = :runId</db:sql>
        <db:input-parameters>#[{ status: vars.final.status, declared: vars.final.declared, parsed: vars.final.parsed,
          ins: vars.final.inserted, upd: vars.final.updated, rej: vars.final.rejected, pct: vars.final.rejectPercent,
          rfp: vars.final.rejectFilePath, reason: (vars.final.failureReason default '')[0 to 254], runId: vars.runId }]</db:input-parameters>
      </db:update>
    </when>
  </choice>
  <flow-ref name="hr-import-notify-subflow" />
  <file:move config-ref="File_Config" sourcePath="#[vars.sourcePath]" targetPath="#[vars.targetDir]"
      overwrite="true" createParentDirectories="true" />
  <logger level="#[if (vars.final.status == 'SUCCESS' or vars.final.status == 'PARTIAL') 'INFO' else 'ERROR']" category="hr.import"
      message="#['runId=' ++ vars.runId ++ ' file=' ++ vars.fileName ++ ' event=RUN_FINISHED status=' ++ vars.final.status ++ ' inserted=' ++ vars.final.inserted ++ ' updated=' ++ vars.final.updated ++ ' rejected=' ++ vars.final.rejected]" />
</sub-flow>

<sub-flow name="hr-import-notify-subflow">
  <ee:transform doc:name="Build email">
    <ee:message><ee:set-payload resource="dwl/email-body.dwl" /></ee:message>
    <ee:variables><ee:set-variable variableName="mail">#[payload]</ee:set-variable></ee:variables>
  </ee:transform>
  <try>
    <until-successful maxRetries="${app.retry.maxAttempts}" millisBetweenRetries="${app.retry.delayMs}">
      <email:send config-ref="SMTP_Config" fromAddress="${smtp.from}" subject="#[vars.mail.subject]">
        <email:to-addresses><email:to-address value="${hr.admin.distributionList}" /></email:to-addresses>
        <email:body contentType="text/plain"><email:content>#[vars.mail.body]</email:content></email:body>
      </email:send>
    </until-successful>
    <set-variable variableName="notificationStatus" value="SENT" />
    <error-handler>
      <on-error-continue type="ANY">
        <logger level="ERROR" category="hr.import.alert"
            message="#['ALERT runId=' ++ vars.runId ++ ' event=EMAIL_FAILED errorType=' ++ error.errorType.identifier]" />
        <set-variable variableName="notificationStatus" value="FAILED" />
      </on-error-continue>
    </error-handler>
  </try>
  <choice>
    <when expression="#[vars.finalStatus != 'DUPLICATE_FILE']">
      <db:update config-ref="Database_Config">
        <db:sql>UPDATE employee_import_runs SET notification_status = :ns WHERE run_id = :runId</db:sql>
        <db:input-parameters>#[{ ns: vars.notificationStatus, runId: vars.runId }]</db:input-parameters>
      </db:update>
    </when>
  </choice>
</sub-flow>
A failed email never reverses the load: the notify subflow sits after the commit and its errors are swallowed and recorded in notification_status.
dwl/email-body.dwl (one template, different subject and wording per status; it only reads counts, IDs and reasons, never personal fields):
%dw 2.0
output application/java
var f = vars.final
fun ts(d) = if (d == null) "n/a" else (d as String {format: "yyyy-MM-dd HH:mm:ss"})
var label = f.status match {
  case "SUCCESS" -> "SUCCESS"
  case "PARTIAL" -> "PARTIAL SUCCESS"
  case "DUPLICATE_FILE" -> "DUPLICATE FILE (SKIPPED)"
  case "EMPTY" -> "EMPTY FILE"
  else -> "FAILED"
}
var intro = f.status match {
  case "SUCCESS" -> "The employee import completed successfully. All records were loaded."
  case "PARTIAL" -> "The employee import completed with status PARTIAL SUCCESS. Some records were rejected."
  case "DUPLICATE_FILE" -> "This file name and checksum were already processed. It was skipped and no records were written."
  case "EMPTY" -> "The file contained no employee records. Nothing was loaded."
  else -> "The employee import FAILED. " ++ (f.failureReason default "See the error log for the run ID below.")
}
var breakdown = (f.rejectSummary map ("- " ++ $.rejectCode ++ " - " ++ $.count ++ " record(s)")) joinBy "\n"
var sample = (f.rejectSample map ("- Row " ++ $.recordIndex ++ " - " ++ ($.employeeId default "n/a") ++ " - " ++ $.rejectReason)) joinBy "\n"
---
{
  subject: "Employee Import " ++ label ++ " - " ++ f.fileName,
  body: "Dear HR Administrator,\n\n" ++ intro ++
    "\n\nRun ID: " ++ f.runId ++
    "\nFile Name: " ++ f.fileName ++ " (" ++ f.fileFormat ++ ")" ++
    "\nSource System: " ++ f.sourceSystem ++
    "\nProcessing Window: " ++ ts(f.startedAt) ++ " to " ++ ts(f.completedAt) ++
    "\n\nRecord Summary\n- Records declared : " ++ (f.declared default "n/a") ++
    "\n- Records parsed : " ++ f.parsed ++ "\n- Records inserted : " ++ f.inserted ++
    "\n- Records updated : " ++ f.updated ++
    "\n- Records rejected : " ++ f.rejected ++ " (" ++ f.rejectPercent ++ "%)" ++
    (if (f.rejected > 0)
      ("\n\nRejection Breakdown\n" ++ breakdown ++
       "\n\nRejected Records (first " ++ sizeOf(f.rejectSample) ++ ")\n" ++ sample ++
       "\n\nA reject file containing all failed records in the original format has been written to: " ++ f.rejectFilePath ++
       "\nPlease correct the rejected records and resubmit only the reject file. The successfully loaded records do not need to be sent again.")
     else "") ++
    "\n\nRegards,\nEmployee Data Integration"
}
Subjects produced: Employee Import SUCCESS - <file>, Employee Import PARTIAL SUCCESS - <file>, Employee Import FAILED - <file>, plus the duplicate and empty variants. The reject sample is capped by app.reject.sampleSize.
Step 8. Global error handling, logging and privacy
8.1 error-handler.xml. One global handler ends every failure the same way: log one consistent line, set the failure reason, finalize (audit row, email, move to the error folder). It uses on-error-continue so the file listener does not re-deliver the file.
<error-handler name="global-error-handler">

  <!-- Duplicate file caught by the unique key under a race -->
  <on-error-continue type="DB:QUERY_EXECUTION" when="#[error.description contains 'uk_import_file']">
    <set-variable variableName="finalStatus" value="DUPLICATE_FILE" />
    <set-variable variableName="targetDir"   value="${app.file.archiveDir}" />
    <flow-ref name="hr-import-finalize-subflow" />
  </on-error-continue>

  <!-- Business-level file rejections: structure, encoding, count mismatch -->
  <on-error-continue type="HR:INVALID_FILE, HR:COUNT_MISMATCH">
    <logger level="ERROR" category="hr.import.alert"
        message="#['ALERT runId=' ++ (vars.runId default 'NO-RUN') ++ ' file=' ++ (vars.fileName default 'unknown') ++ ' event=FILE_REJECTED type=' ++ error.errorType.identifier ++ ' reason=' ++ error.description]" />
    <set-variable variableName="finalStatus"   value="FAILED" />
    <set-variable variableName="failureReason" value="#[error.description]" />
    <set-variable variableName="targetDir"     value="${app.file.errorDir}" />
    <flow-ref name="hr-import-safe-finalize-subflow" />
  </on-error-continue>

  <!-- Everything else: unexpected error -->
  <on-error-continue type="ANY">
    <ee:transform>
      <ee:message><ee:set-payload><![CDATA[%dw 2.0
output application/java
---
// Strip anything inside quotes: database messages can echo field values.
(error.description default "") replace /'[^']*'/ with "'***'"]]></ee:set-payload></ee:message>
      <ee:variables><ee:set-variable variableName="safeDescription">#[payload]</ee:set-variable></ee:variables>
    </ee:transform>
    <logger level="ERROR" category="hr.import.alert"
        message="#['ALERT runId=' ++ (vars.runId default 'NO-RUN') ++ ' file=' ++ (vars.fileName default 'unknown') ++ ' event=UNEXPECTED_ERROR type=' ++ error.errorType.namespace ++ ':' ++ error.errorType.identifier ++ ' detail=' ++ vars.safeDescription]" />
    <set-variable variableName="finalStatus"   value="FAILED" />
    <set-variable variableName="failureReason" value="#['Unexpected processing error (' ++ error.errorType.identifier ++ '). See the log for run ' ++ (vars.runId default 'NO-RUN')]" />
    <set-variable variableName="targetDir"     value="${app.file.errorDir}" />
    <flow-ref name="hr-import-safe-finalize-subflow" />
  </on-error-continue>
</error-handler>

<sub-flow name="hr-import-safe-finalize-subflow">
  <try>
    <flow-ref name="hr-import-finalize-subflow" />
    <error-handler>
      <on-error-continue type="ANY">
        <logger level="ERROR" category="hr.import.alert"
            message="#['ALERT runId=' ++ (vars.runId default 'NO-RUN') ++ ' event=AUDIT_FALLBACK status=' ++ vars.finalStatus ++ ' note=run row or email could not be written']" />
        <try>
          <file:move config-ref="File_Config" sourcePath="#[vars.sourcePath]" targetPath="${app.file.errorDir}" overwrite="true" createParentDirectories="true" />
          <error-handler><on-error-continue type="ANY"><logger level="ERROR" message="event=MOVE_FAILED" /></on-error-continue></error-handler>
        </try>
      </on-error-continue>
    </error-handler>
  </try>
</sub-flow>
Also add in global-config.xml:
<configuration defaultErrorHandler-ref="global-error-handler" />
Two details:
•	A file that fails before runId exists still gets a log line (NO-RUN) and an error-folder move.
•	A HR:INVALID_FILE rejection has a run row because the duplicate-check subflow runs before parsing, so the audit record exists with status FAILED.
8.2 Retries. Transient DB and SMTP failures are retried by the reconnection setting on the connectors (Step 7.0) and by until-successful around email:send. Keep the limits in properties (app.retry.maxAttempts, app.retry.delayMs) so you can change them per environment.
8.3 Logging standard. Log only this shape: runId=... file=... event=... key=value. Use these levels:
Level	Use for
INFO	Run lifecycle: picked up, validated (counts), batch committed (size), run finished
WARN	A batch rolled back and fell back to row by row; email retry
ERROR	Failed run, threshold exceeded, email finally failed, unexpected error
DEBUG	Technical details with no data values (off by default)
src/main/resources/log4j2.xml (note the connector loggers: the DB connector at DEBUG prints bound parameters, which would leak personal data):
<Configuration>
  <Appenders>
    <Console name="Console"><PatternLayout pattern="%d{ISO8601} %-5p [%t] %c - %m%n" /></Console>
  </Appenders>
  <Loggers>
    <AsyncLogger name="hr.import" level="INFO" />
    <AsyncLogger name="hr.import.alert" level="ERROR" />
    <AsyncLogger name="org.mule.extension.db" level="WARN" />
    <AsyncLogger name="com.mysql" level="WARN" />
    <AsyncLogger name="org.mule.runtime.core" level="WARN" />
    <AsyncRoot level="INFO"><AppenderRef ref="Console" /></AsyncRoot>
  </Loggers>
</Configuration>
8.4 Zero-exposure rules (acceptance criterion 10). Treat these as a checklist at every code review:
1.	No logger or raise-error ever contains payload, vars.records, vars.validated, vars.rejects, or error.description from a DB or DataWeave error without the quote-stripping step above.
2.	Validation messages name the field and, for reference data, the department, location, designation or manager code. They never echo the date of birth, mobile, or email value.
3.	The email body is built only from vars.final, which holds counts, IDs, codes and reasons.
4.	The reject file does contain the personal fields (HR must fix and resubmit them), so keep app.file.rejectDir access restricted; it is a file, not a log or email.
5.	There are no compensation fields in this model. If you add one later, keep it out of the canonical logs and email exactly like date of birth.
6.	Never enable payload capture in Anypoint Monitoring or DEBUG logging of the DB connector on CloudHub.
7.	After a test run, search the log for the sample values and expect nothing back: grep -E "1994-03-18|9884012345|karthik.s@" app.log.
Step 9. Write the MUnit tests
Goal from the brief: tests for both formats and every negative scenario, with file system, database and SMTP mocked, and coverage as close to 100% as you can reach (state valid reasons for anything left out).
9.1 Make the flows testable first.
1.	A file listener cannot be called from a test. Move everything after the listener in hr-import-main-flow into a private flow hr-import-process-flow and leave only <flow-ref name="hr-import-process-flow" /> under the listener. Tests then call hr-import-process-flow.
2.	Give every DB, file and email operation a unique doc:name (for example Select employees, Bulk upsert employees, Move file, Send email). Mocks match on doc:name.
3.	The batch job runs asynchronously. Test its contents by calling hr-import-upsert-bulk-subflow, hr-import-pass2-managers-subflow and hr-import-final-counts-subflow directly, and for one end-to-end test add <munit-tools:sleep time="3000" /> before the validations.
9.2 Sample files under src/test/resources/samples/:
EMP_IMPORT_valid.csv, which is your sample with one bad row (single line per record):
employeeId,firstName,lastName,dateOfBirth,dateOfJoining,officialEmail,mobile,departmentCode,designation,locationCode,employmentType,managerId
EMP10041,Karthik,Subramanian,1994-03-18,2026-09-15,karthik.s@company.com,+91-9884012345,DEPT-ENG,Senior Engineer,LOC-CHN-01,PERMANENT,EMP10002
EMP10042,Priya,Nair,1996-11-02,2026-09-15,priya.nair@company.com,+91-9884012346,DEPT-ENG,Engineer,LOC-CHN-01,PERMANENT,EMP10041
EMP10043,Vignesh,Murugan,1990-07-25,2026-09-16,vignesh.m@company.com,+91-9884012347,DEPT-FIN,Finance Analyst,LOC-BLR-02,PERMANENT,EMP10008
EMP10044,Aarthi,Balaji,1999-01-30,2026-09-16,aarthi.b@company.com,+91-9884012348,DEPT-HR,HR Executive,LOC-CHN-01,CONTRACT,EMP10005
EMP10045,Rahul,Verma,1988-05-14,2026-09-20,rahul.verma@company.com,+91-9884012349,DEPT-XXX,Manager,LOC-CHN-01,PERMANENT,EMP10003
EMP_IMPORT_valid.xml is the identical content as XML. One compact line per employee is fine:
<?xml version="1.0" encoding="UTF-8"?>
<employeeImport>
  <header><sourceSystem>HRMS-PRD</sourceSystem><generatedAt>2026-09-11T08:00:00+05:30</generatedAt><recordCount>5</recordCount></header>
  <employees>
    <employee><employeeId>EMP10041</employeeId><firstName>Karthik</firstName><lastName>Subramanian</lastName><dateOfBirth>1994-03-18</dateOfBirth><dateOfJoining>2026-09-15</dateOfJoining><officialEmail>karthik.s@company.com</officialEmail><mobile>+91-9884012345</mobile><departmentCode>DEPT-ENG</departmentCode><designation>Senior Engineer</designation><locationCode>LOC-CHN-01</locationCode><employmentType>PERMANENT</employmentType><managerId>EMP10002</managerId></employee>
    <employee><employeeId>EMP10042</employeeId><firstName>Priya</firstName><lastName>Nair</lastName><dateOfBirth>1996-11-02</dateOfBirth><dateOfJoining>2026-09-15</dateOfJoining><officialEmail>priya.nair@company.com</officialEmail><mobile>+91-9884012346</mobile><departmentCode>DEPT-ENG</departmentCode><designation>Engineer</designation><locationCode>LOC-CHN-01</locationCode><employmentType>PERMANENT</employmentType><managerId>EMP10041</managerId></employee>
    <employee><employeeId>EMP10043</employeeId><firstName>Vignesh</firstName><lastName>Murugan</lastName><dateOfBirth>1990-07-25</dateOfBirth><dateOfJoining>2026-09-16</dateOfJoining><officialEmail>vignesh.m@company.com</officialEmail><mobile>+91-9884012347</mobile><departmentCode>DEPT-FIN</departmentCode><designation>Finance Analyst</designation><locationCode>LOC-BLR-02</locationCode><employmentType>PERMANENT</employmentType><managerId>EMP10008</managerId></employee>
    <employee><employeeId>EMP10044</employeeId><firstName>Aarthi</firstName><lastName>Balaji</lastName><dateOfBirth>1999-01-30</dateOfBirth><dateOfJoining>2026-09-16</dateOfJoining><officialEmail>aarthi.b@company.com</officialEmail><mobile>+91-9884012348</mobile><departmentCode>DEPT-HR</departmentCode><designation>HR Executive</designation><locationCode>LOC-CHN-01</locationCode><employmentType>CONTRACT</employmentType><managerId>EMP10005</managerId></employee>
    <employee><employeeId>EMP10045</employeeId><firstName>Rahul</firstName><lastName>Verma</lastName><dateOfBirth>1988-05-14</dateOfBirth><dateOfJoining>2026-09-20</dateOfJoining><officialEmail>rahul.verma@company.com</officialEmail><mobile>+91-9884012349</mobile><departmentCode>DEPT-XXX</departmentCode><designation>Manager</designation><locationCode>LOC-CHN-01</locationCode><employmentType>PERMANENT</employmentType><managerId>EMP10003</managerId></employee>
  </employees>
</employeeImport>
Create the negative variants by copying these two files and changing one thing each (names in the table below). Dates of joining in 2026-09 are in the past or within tolerance today; if a future-date test depends on "today", compute dates in the test instead of hard-coding them.
Mock data for the database (db-masters.json, db-employees.json), returned from the mocked selects:
[
  { "department_code": "DEPT-ENG", "department_key": 1 },
  { "department_code": "DEPT-FIN", "department_key": 2 },
  { "department_code": "DEPT-HR",  "department_key": 3 }
]

[
  { "employee_id": "EMP10002", "official_email": "seed.manager@company.com" },
  { "employee_id": "EMP10003", "official_email": "m3@company.com" },
  { "employee_id": "EMP10005", "official_email": "m5@company.com" },
  { "employee_id": "EMP10008", "official_email": "m8@company.com" }
]
9.3 One complete test as the pattern (copy it for the others):
<munit:config name="hr-import-csv-test.xml" />

<munit:test name="csv-happy-path-partial-test" description="CSV: 4 accepted, 1 rejected for DEPT-XXX, PARTIAL email">
  <munit:behavior>
    <munit-tools:mock-when processor="db:select">
      <munit-tools:with-attributes><munit-tools:with-attribute attributeName="doc:name" whereValue="Select employees" /></munit-tools:with-attributes>
      <munit-tools:then-return><munit-tools:payload value="#[readUrl('classpath://samples/db-employees.json', 'application/json')]" /></munit-tools:then-return>
    </munit-tools:mock-when>
    <!-- repeat mock-when for: Select run by checksum (return []), Insert run row, Select departments/locations/grades,
         Insert rejects, Write reject file (file:write), Move file (file:move), Send email (email:send), Update run row -->
    <munit:set-event>
      <munit:payload value="#[readUrl('classpath://samples/EMP_IMPORT_valid.csv', 'text/plain')]" />
      <munit:attributes value="#[{ fileName: 'EMP_IMPORT_20260911.csv', path: '/data/hr/inbound/EMP_IMPORT_20260911.csv' }]" />
    </munit:set-event>
  </munit:behavior>
  <munit:execution>
    <flow-ref name="hr-import-process-flow" />
  </munit:execution>
  <munit:validation>
    <munit-tools:assert-that expression="#[vars.summary.rejected]" is="#[MunitTools::equalTo(1)]" />
    <munit-tools:assert-that expression="#[(vars.validated filter ($.action == 'REJECT'))[0].rejectReason]" is="#[MunitTools::containsString('DEPT-XXX')]" />
    <munit-tools:assert-that expression="#[vars.mail.body]" is="#[MunitTools::not(MunitTools::containsString('1994-03-18'))]" />
    <munit-tools:verify-call processor="email:send" times="1" />
    <munit-tools:verify-call processor="file:move" times="1" />
  </munit:validation>
</munit:test>
9.4 Test list. Build one test per row; each row maps to a brief scenario.
Test	Input change	What to assert
csv-happy-path, xml-happy-path	the two valid files	5 parsed, 1 rejected (DEPT-XXX), 4 upserts, email PARTIAL
csv-xml-equivalence	both valid files	vars.records from CSV equals XML result (assert-that ... equalTo), same counts
forward-reference	manager row placed after the report row (the sample already does this if you swap rows 1 and 2)	both accepted, no UNRESOLVED_MANAGER; pass 2 called with both links
unresolved-department / location / designation	unknown code	reject code names the value, e.g. UNRESOLVED_LOCATION and the code text
unresolved-manager	manager ID in neither file nor DB	UNRESOLVED_MANAGER; a manager that is itself rejected also cascades
circular-manager	A reports to B, B reports to A, and one self-manager	all involved rows CIRCULAR_MANAGER
duplicate-in-file	same employeeId twice	one row written, second DUPLICATE_IN_FILE
duplicate-in-db (three strategies)	ID that exists in db-employees.json	UPDATE strategy gives UPDATE; INSERT_NEW/REJECT give DUPLICATE_IN_DB with strategy named
duplicate-email	email used by another ID in DB or file	DUPLICATE_EMAIL
missing-mandatory-field	blank employeeId, officialEmail etc.	MISSING_FIELD naming the field
invalid-values	bad email, bad mobile, 2026-13-40, joining date 90 days ahead, DOB giving age 17, type FREELANCE	one specific code each
threshold-abort	3 of 5 rows bad (60%)	verify-call on Bulk upsert employees times 0; email subject contains FAILED; file moved to the error folder
malformed-csv-header	columns reordered or one missing	HR:INVALID_FILE, file to error folder, no DB write
malformed-xml	truncated XML, or missing employees element	same
bad-encoding	bytes that are not UTF-8	File encoding is not valid UTF-8
count-mismatch	recordCount 7, 5 rows	HR:COUNT_MISMATCH and the message holds both numbers
empty-file	header only, or zero bytes	status EMPTY, no error thrown, one email
duplicate-file	mock checksum select to return a SUCCESS row	no insert of run row, email subject has DUPLICATE FILE, file archived
db-batch-failure	mock Bulk upsert employees to raise DB:QUERY_EXECUTION	WARN path, per-record insert called, no double count in final summary
email-failure	mock Send email to raise EMAIL:CONNECTIVITY	notificationStatus is FAILED, run row still SUCCESS/PARTIAL, no rollback
unexpected-error	mock the refdata select to raise MULE:EXPRESSION	global handler logs once, FAILED email, file to error folder
sensitive-data	valid file	email body and every mocked logger input contain none of the DOB, mobile or email values
reject-file-format	valid CSV and valid XML	reject output keeps original columns plus rejectReason, and parses back with the same transform
validation-dwl-unit	call the script with a handcrafted vars.refs	one assertion per rule so each branch is covered
To raise an error from a mock use <munit-tools:then-return><munit-tools:error typeId="DB:QUERY_EXECUTION" /></munit-tools:then-return>.
9.5 Coverage. Add to pom.xml and run mvn clean test (or right-click the project > Run MUnit suite with coverage):
<plugin>
  <groupId>com.mulesoft.munit.tools</groupId>
  <artifactId>munit-maven-plugin</artifactId>
  <version>${munit.version}</version>
  <executions><execution><id>test</id><phase>test</phase><goals><goal>test</goal><goal>coverage-report</goal></goals></execution></executions>
  <configuration>
    <coverage>
      <runCoverage>true</runCoverage>
      <failBuild>true</failBuild>
      <requiredApplicationCoverage>100</requiredApplicationCoverage>
      <formats><format>html</format></formats>
    </coverage>
  </configuration>
</plugin>
If some component cannot reach 100% (for example the listener source, or on-complete of the batch), exclude it with <ignoreFlows> and write the valid reason in the README, as the brief allows.
Step 10. Run locally, deploy to CloudHub, add policies and alerts
10.1 Run locally first.
1.	Create the four folders (inbound, archive, error, reject) and set their paths in app-config-dev.yaml. On Windows use paths like C:/hr/inbound.
2.	Right-click the project > Run As > Mule Application (configure). Under Arguments add -M-Dmule.env=dev -M-Dmule.key=MySecretKey123.
3.	Run the SQL script, start MailHog, and copy EMP_IMPORT_20260911.csv into the inbound folder.
4.	Watch the console for the run lifecycle lines. Expect: FILE_PICKED_UP, VALIDATED, BATCH_COMMITTED, RUN_FINISHED status=PARTIAL.
5.	Verify in MySQL and MailHog:
SELECT run_id, run_status, inserted_count, updated_count, rejected_count, reject_percent, notification_status
  FROM employee_import_runs ORDER BY started_at DESC LIMIT 1;
SELECT employee_id, department_key, location_key, grade, manager_key FROM employees WHERE employee_id LIKE 'EMP100%';
SELECT * FROM employee_import_rejects;
6.	Drop the same file again (copy it back into inbound). Expect a DUPLICATE FILE (SKIPPED) email and no new rows.
7.	First delete the test employees EMP10041 to EMP10044 and the run rows (or use a fresh database), then drop the XML file. Expect the same counts and the same rows as the CSV run; this proves criterion 1.
10.2 Local-only vs CloudHub file handling. CloudHub workers have no shared network folder, so the File connector cannot watch your laptop folder. Choose one:
•	Use an SFTP connector instead of File on CloudHub (change file:listener to sftp:on-new-or-updated-file and the move/write operations to their SFTP versions; the process flow stays identical).
•	Or deploy the working app to CloudHub using the worker's local disk (/tmp/hr/...) and show the demo by uploading through a small POST /imports/upload endpoint that writes the file into the inbound folder.
The brief says a local run scores lower than CloudHub but is allowed, so get the local run perfect first. Use SFTP in production design and say so in the HLD.
10.3 Deploy to CloudHub.
1.	Replace placeholders: set api.id and api.autodiscovery.name with the values from API Manager; use mule.env=dev.
2.	Right-click the project > Anypoint Platform > Deploy to CloudHub. Choose the Sandbox environment, a unique app name, runtime 4.x, worker size 0.1 vCore.
3.	In Properties add mule.env = dev and mule.key = your encryption key. Tick "Secure" for mule.key.
4.	Deploy and watch Runtime Manager logs. The app should show STARTED and the API should appear as Active in API Manager.
5.	For repeatable builds also set <cloudHubDeployment> in pom.xml with the same values so mvn deploy -DmuleDeploy works.
10.4 Apply API policies (API Manager > your API > Policies). Apply these at minimum and note them in the HLD:
Policy	Purpose	Setting
Client ID Enforcement	Only registered clients call the status API	Credentials from headers client_id, client_secret
Rate Limiting	Protect the status and reprocess endpoints	e.g. 60 requests per minute
IP Allowlist	Only HR network ranges	Set your demo IP
Header Injection / Removal	Add security headers, strip internal headers	X-Content-Type-Options: nosniff
The file watcher itself has no HTTP surface, so the policies protect only the REST endpoints from Step 4. Say so; judges look for this clarity.
10.5 Alerts and monitoring.
1.	In Runtime Manager > Alerts create: (a) a log-based alert in Anypoint Monitoring when a log line contains ALERT at ERROR level (every failed run, threshold abort, and email failure writes one), notified to the ops email; (b) "Worker not responding"; (c) "CPU or memory above 80%".
2.	In Anypoint Monitoring create a custom dashboard with panels: runs per status, average rejection percent, batch duration.
3.	The "rejection rate above threshold" alert is the event=THRESHOLD_EXCEEDED log line from Step 7.6. Optionally add a second email to the ops list when vars.final.rejectPercent is above 20 as a soft warning.
4.	Each lifecycle log line carries runId, so searching one run ID in Monitoring shows the file name, format, batch progress and counts, which is what the brief asks for.
Step 11. High-Level Design document and final checklist
11.1 HLD outline (docs/HLD.docx, 6 to 10 pages). Write it on day 5 from what you built:
1.	Purpose, scope and the scenario in two paragraphs.
2.	Architecture diagram: HR system, inbound folder (or SFTP), Process API, System API, MySQL, SMTP, Anypoint Platform (API Manager, Monitoring).
3.	API-led layers and why each exists, with the RAML endpoints.
4.	Sequence diagram of one run, from file pick-up to email, including the abort branch.
5.	Canonical model: the 12 fields and the derived fields (keys, grade, action).
6.	Validation rule table: rule, code, message pattern (copy from record-validation.dwl).
7.	Forward reference design: pass 1 with manager_key NULL, pass 2 update, and why it removes ordering problems.
8.	Persistence design: batch size 200, one transaction per batch, per-record fallback, idempotency by (file_name, checksum).
9.	Error handling matrix: each negative scenario, where it is detected, resulting status, email and destination folder.
10.	Security and privacy: secure properties, no PII in logs or email, policies, reject file handling.
11.	Non-functional: logging levels, alerts, retry limits, caching, Object Store, known limits (validation holds the file in memory; for files beyond a few hundred thousand rows add a staging table).
12.	Deployment: environments, properties, domain project, CI notes, Git branching.
11.2 Final acceptance checklist. Tick each one with evidence (screenshot or query) in your demo.
•	☐ Valid CSV and equivalent XML produce identical rows and counts (reset the test employees and run rows between the two runs, otherwise the second run reports UPDATEs instead of INSERTs).
•	☐ Every accepted employee row has department_key, location_key, grade and manager_key filled.
•	☐ Swap two rows so a manager comes later in the file; both are accepted.
•	☐ A row with DEPT-XXX is rejected with departmentCode DEPT-XXX not found.
•	☐ A reject file exists in the same format as the input with a rejectReason column or element, and re-importing only that file after fixing it works.
•	☐ The three emails differ: success (no rejects), partial (sample), failed (threshold or malformed).
•	☐ A file with more than 40% bad rows leaves employees untouched and sends the failure email.
•	☐ Dropping the same file again creates no new rows and sends the duplicate email.
•	☐ A 5,000-row generated file shows several BATCH_COMMITTED size=200 lines and the correct final counts, and batches_completed in the run row.
•	☐ The log search for sample DOB, mobile and email values returns nothing; the email bodies contain none of them either.
•	☐ MUnit passes for all tests in the table of Step 9 and the coverage report is attached (or reasons are documented).
•	☐ Git history shows commits and merged pull requests from every team member, and one resolved merge conflict.
•	☐ RAML, Auto Discovery, secure properties, global error handler, domain project, caching, Object Store, batch and policies are each shown in the demo.
11.3 How to use your generator prompt with this guide. Your prompt asks an AI for six files first (DDL, two YAML files, three DataWeave files) and then flows, MUnit and HLD on "PROCEED". This guide already contains reviewed versions of all of those, so use the prompt only to cross-check or extend them. Treat any AI-generated code as a draft: always run the DataWeave in the Playground and the flows in Studio, because small syntax details (module names, connector attribute names) vary with the runtime version you install.
11.4 Common problems and fixes.
Symptom	Likely cause	Fix
Listener never fires	Wrong folder path, or file still being written	Check app.file.inboundDir; keep the size-check attributes
Cannot coerce String to Date in validation	A date cell not in yyyy-MM-dd	The transform returns null for it; the validator then reports INVALID_DATE
Secure property not decrypted	Wrong or missing mule.key	Pass the same key used with the encryption tool
Duplicate entry ... uk_import_file	Same file name and checksum again	Expected; it should end as a duplicate email
MUnit cannot find a processor to mock	doc:name differs from the mock	Make the names identical
Emails not appearing	MailHog not running or wrong port	smtp.port=1025, check localhost:8025
All rows rejected for managers	Seed managers EMP10003, EMP10005, EMP10008 are missing	Add them to the seed data (Step 3)


---
## Local developer setup and verification (implemented in this repository)

### Project structure delivered
This repository now includes the Mule 4 project skeleton and implementation assets described in this guide:
- `pom.xml`, `mule-artifact.json`, `.gitignore`
- `src/main/mule/*.xml` flows (intake/orchestration, parsing, validation, rejects, persistence, notifications, error handling)
- `src/main/resources/config` property files (`app-config-dev.yaml`, secure template)
- `src/main/resources/dwl` DataWeave modules for canonical parsing, validation, reject output, email body
- `src/main/resources/sql/ddl.sql`
- `src/main/resources/api/hr-import-api.raml`
- `src/test/munit` and `src/test/resources/samples`

### Safe local secrets handling
- Copy `src/main/resources/config/app-config-secure-dev.template.yaml` to `src/main/resources/config/app-config-secure-dev.yaml` locally.
- Encrypt values with Mule Secure Properties Tool.
- Run with `-Dmule.key=<your-key>` and do not commit real keys/passwords.

### Commands run by the coding agent in this environment
```bash
# static XML validation (all Mule/MUnit XML files)
python - <<'PY'
from pathlib import Path
import xml.etree.ElementTree as ET
for p in sorted(Path('src').glob('**/*.xml')):
    ET.parse(p)
print('XML_OK')
PY

# Mule Maven build
mvn -B -DskipTests package
```

### Verification result and environment limitation
- XML validation passed (`XML_OK`).
- Maven build could not complete in this sandbox because the Mule Maven plugin and Mule packaging extension could not be resolved from `https://repository.mulesoft.org/...` (DNS/network resolution failure in this environment), causing `Unknown packaging: mule-application`.
- On a developer machine/CI runner with access to MuleSoft artifact repositories, run:
  ```bash
  mvn -B clean test
  ```
  and then run locally with Mule runtime arguments:
  ```bash
  -Dmule.env=dev -Dmule.key=<your-key>
  ```
