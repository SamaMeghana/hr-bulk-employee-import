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
