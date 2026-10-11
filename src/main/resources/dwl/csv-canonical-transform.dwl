%dw 2.0
output application/java
import toCanonical from dwl::canonicalLib
var text = (payload as String {encoding: "UTF-8"}) replace "﻿" with ""
var cleaned = ((text splitBy /?
/) filter (!($ startsWith "#") and !isEmpty(trim($)))) joinBy "
"
var rows = if (isEmpty(cleaned)) [] else read(cleaned, "application/csv", { header: true })
---
rows map (r, idx) -> toCanonical(r, idx)
