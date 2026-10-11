%dw 2.0
output application/java
import toCanonical from dwl::canonicalLib
---
(payload.employeeImport.employees.*employee default []) map (e, idx) -> toCanonical(e, idx)
