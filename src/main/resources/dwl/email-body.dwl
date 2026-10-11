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
var breakdown = (f.rejectSummary map ("- " ++ $.rejectCode ++ " - " ++ $.count ++ " record(s)")) joinBy "
"
var sample = (f.rejectSample map ("- Row " ++ $.recordIndex ++ " - " ++ ($.employeeId default "n/a") ++ " - " ++ $.rejectReason)) joinBy "
"
---
{
  subject: "Employee Import " ++ label ++ " - " ++ f.fileName,
  body: "Dear HR Administrator,

" ++ intro ++
    "

Run ID: " ++ f.runId ++
    "
File Name: " ++ f.fileName ++ " (" ++ f.fileFormat ++ ")" ++
    "
Source System: " ++ f.sourceSystem ++
    "
Processing Window: " ++ ts(f.startedAt) ++ " to " ++ ts(f.completedAt) ++
    "

Record Summary
- Records declared : " ++ (f.declared default "n/a") ++
    "
- Records parsed : " ++ f.parsed ++ "
- Records inserted : " ++ f.inserted ++
    "
- Records updated : " ++ f.updated ++
    "
- Records rejected : " ++ f.rejected ++ " (" ++ f.rejectPercent ++ "%)" ++
    (if (f.rejected > 0)
      ("

Rejection Breakdown
" ++ breakdown ++
       "

Rejected Records (first " ++ sizeOf(f.rejectSample) ++ ")
" ++ sample ++
       "

A reject file containing all failed records in the original format has been written to: " ++ f.rejectFilePath ++
       "
Please correct the rejected records and resubmit only the reject file. The successfully loaded records do not need to be sent again.")
     else "") ++
    "

Regards,
Employee Data Integration"
}
