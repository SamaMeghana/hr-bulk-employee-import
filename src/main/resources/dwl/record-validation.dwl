%dw 2.0
output application/java
import isBlank from dw::core::Strings
import daysBetween from dw::core::Periods

var cfg     = vars.cfg
var depts   = vars.refs.departments default {}
var locs    = vars.refs.locations default {}
var grades  = vars.refs.grades default {}
var dbEmp   = vars.refs.employees default {}
var dbMail  = vars.refs.emails default {}
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
