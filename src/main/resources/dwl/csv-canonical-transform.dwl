%dw 2.0
output application/java
import toCanonical from dwl::canonicalLib

var text = (payload as String {encoding: "UTF-8"}) replace "\uFEFF" with ""
var lines = text splitBy /\r?\n/
var cleaned = (lines filter ((line) -> !((line startsWith "#") or isEmpty(trim(line))))) joinBy "\n"
var rows = if (isEmpty(trim(cleaned))) [] else read(cleaned, "application/csv", { header: true })
---
rows map ((r, idx) -> toCanonical(r, idx))
