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
