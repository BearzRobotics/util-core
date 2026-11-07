#!/bin/sh
# date: differential tests against GNU date 9.7 (C locale). References: GNU
# manual "date invocation" and "Date input formats"; POSIX.1-2024 date.
# Strings that depend on the current time are compared through formats that do
# not change within a second (%F), or are anchored with an explicit time.
UTIL="date"
. "$(dirname "$0")/testlib.sh"
help_cmp
W="$(mktemp -d)"; cd "$W"
TZS="UTC America/New_York Europe/London Asia/Kolkata Australia/Sydney"
E1=1700000000; E2=951782400; E3=1709164800; E4=0; E5=-86400; E6=2147483647; E7=1234567890; E8=4102444800

printf "\n[ Output formats ]\n"
for tzv in $TZS; do
    for e in $E1 $E2 $E3 $E4 $E5 $E6 $E7 $E8; do
        TZ=$tzv run_cmp "default @$e $tzv" -d @$e
        TZ=$tzv run_cmp "-R @$e $tzv" -d @$e -R
        TZ=$tzv run_cmp "-I @$e $tzv" -d @$e -I
        TZ=$tzv run_cmp "-Iseconds @$e $tzv" -d @$e -Iseconds
        TZ=$tzv run_cmp "-Ihours @$e $tzv" -d @$e -Ihours
        TZ=$tzv run_cmp "-Iminutes @$e $tzv" -d @$e -Iminutes
        TZ=$tzv run_cmp "-Ins @$e $tzv" -d @$e -Ins
        TZ=$tzv run_cmp "--rfc-3339=seconds @$e $tzv" -d @$e --rfc-3339=seconds
    done
done
for f in %a %A %b %B %c %C %d %D %e %F %g %G %h %H %I %j %k %l %m %M %n %N %p %P %r %R %s %S %t %T %u %U %V %w %W %x %X %y %Y %z %:z %::z %:::z %Z %% %q %E %Ey %Od %_d %-d %0e %^a %#a %^B %#B %#p %^p %10Y %-10Y %_10d %010e %5N %3N %-N %:z %10z %_10z %-z %_H %-H %-m %_m %^Z %#Z %+4Y %+Y '%Y-%m-%d %H:%M:%S' '%s.%N' 'a%%b' '%' '%5' '%Q'; do
    for e in $E1 $E2; do
        run_cmp "fmt $f @$e" -d @$e "+$f"
        TZ=Asia/Kolkata run_cmp "fmt $f @$e IST" -d @$e "+$f"
        TZ=America/New_York run_cmp "fmt $f @$e NY" -d @$e "+$f"
    done
done
run_cmp "-u"                  -u -d @$E1
run_cmp "--utc"               --utc -d @$E1
run_cmp "--universal"         --universal -d @$E1
TZ=America/New_York run_cmp "-u overrides TZ" -u -d @$E1
run_cmp "--resolution"        --resolution
run_cmp "-R both"             -R -I
run_cmp "-I bad"              -I bad -d @0
run_cmp "-I ambiguous"        -Ih -d @0
run_cmp "--rfc-3339 hours"    --rfc-3339=hours -d @0
run_cmp "--rfc-3339 bad"      --rfc-3339=x -d @0
run_cmp "--iso-8601=date"     --iso-8601=date -d @0
run_cmp "--rfc-email"         --rfc-email -d @0
run_cmp "--rfc-2822"          --rfc-2822 -d @0
run_cmp "multiple formats"    +%s +%Y -d @0
run_cmp "format and -R"       -R +%s -d @0

printf "\n[ -d inputs ]\n"
D1="2024-02-29 12:34:56"
for s in '2024-02-29' '2024-02-30' '2023-02-29' '2024-13-01' '2024-00-10' '1999-12-31 23:59:59' '2024-02-29 12:34' '2024-02-29T12:34:56' '2024-02-29T12:34:56Z' '2024-02-29T12:34:56+05:30' '2024-02-29 12:34:56.789' '2024-02-29 12:34:56,789' '2024-02-29 12:34:56.123456789012' '12:34' '12:34:56' '1:2' '1:02:03' '23:59:60' '24:00' '25:00' '12am' '12pm' '1am' '11pm' '12:30am' '12:30 pm' '0pm' '13pm' '3 pm' '3 P.M.' 'noon' 'midnight' '20240229' '2024-2-9' '2024/02/29' '02/29/2024' '2/29/24' '2/29' '02/29' '29 feb 2024' 'feb 29 2024' 'Feb 29, 2024' 'feb 29' 'February 29 2024 5pm' '29-feb-2024' '29 Feb' 'Thu Feb 29 2024' 'Thursday' 'thu' 'next thu' 'last thu' 'this thu' 'thu next' 'tomorrow 5pm' 'yesterday noon' 'next friday 9am' 'monday next week' '@0' '@-1' '@1.5' '@-1.5' '@1700000000' '@99999999999' '@' '@x' '@ 5' 'UTC' '12:00 UTC' '12:00 GMT' '12:00 EST' '12:00 EDT' '12:00 PST' '12:00 CET' '12:00 CEST' '12:00 JST' '12:00 IST' '12:00 Z' '12:00 A' '12:00 M' '12:00 N' '12:00 Y' '12:00 +0100' '12:00 -0500' '12:00 +01:00' '12:00 -05:30' '12:00 +1' '12:00 -12' '12:00 +24' '12:00 +25' '12:00 UTC+3' '12:00 UTC-3' '12:00 EST5' '12:00 +0530 +1 day' 'TZ="America/New_York" 12:00' 'TZ="Asia/Tokyo" 2024-01-01 00:00' 'TZ="UTC" next friday' 'TZ="Invalid/Zone" 12:00' '(comment) 12:00' '12:00 (comment (nested)) tomorrow' '' ' ' 'garbage' '12:00 garbage' '2024 02 29' '2024-02-29 2024-03-01' '12:00 13:00' 'Jan Feb' '1 2 3' '1 2' '99' '1999' '123456' '20240229T123456' '2024-02-29 +1 day' '2024-02-29 12:00 +1 day' '2024-02-29 12:00 -1 month' '2024-01-31 +1 month' '2024-03-31 -1 month' '2024-02-29 +1 year' '2024-02-29 -1 year' '2024-12-31 23:59:59 +1 sec' '2024-01-01 00:00:00 -1 sec' '2024-02-29 12:00 +36 hours' '2024-02-29 12:00 next monday' '2024-02-29 12:00 monday' '2024-02-29 3rd monday' '2024-02-29 second monday' '2024-02-29 1 monday' '2024-02-29 2 monday' '2024-02-29 -1 monday' '2024-02-29 last monday' '2024-02-29 12:00 last day' '2024-02-29 next day' '2024-02-29 this day' '2024-02-29 12:00 saturday ago' '2024-02-29 +1 week ago' '2024-02-29 1 fortnight ago' '2024-02-29 12:00 UTC +1 day' '2024-02-29 12:00 EST +1 day' '2024-02-29 12:00 +1 hour UTC' '5 days ago 2024-02-29' '2024-02-29 5 days ago' '3pm 2024-02-29' '2024-02-29 3pm' '2024-02-29 10:00 3pm' '2024-02-29 25:00' '2024-02-29 12:60' '2024-02-29 12:30:61' '0000-01-01' '9999-12-31' '10000-01-01' '-0001-01-01' '1969-12-31 23:59:59' '1970-01-01 00:00:00 UTC' '1900-01-01' '2038-01-19 03:14:08 UTC' '2100-02-29' '2000-02-29' '1900-02-29' '3 jan' '3 january 2024 10:11' 'sept 3' 'sep 3' 'Sept. 3' 'Sep. 3 2024' 'may 5' 'MAY 5 2020' 'aug' 'dec 25 12:00' 'Dec 25 12:00 2024'; do
    for tzv in UTC America/New_York; do
        TZ=$tzv run_cmp "-d '$s' $tzv" -d "$s" '+%s.%N %F %T %Z'
    done
done

printf "\n[ DST boundaries ]\n"
for s in '2024-03-10 01:59:59' '2024-03-10 02:00:00' '2024-03-10 02:30:00' '2024-03-10 03:00:00' '2024-11-03 00:59:59' '2024-11-03 01:00:00' '2024-11-03 01:30:00' '2024-11-03 01:30:00 EDT' '2024-11-03 01:30:00 EST' '2024-11-03 02:00:00' '2024-03-09 02:30 +1 day' '2024-03-10 12:00 -1 day' '2024-11-02 01:30 +1 day' '2024-03-10 00:00 +24 hours' '2024-03-10 00:00 +1 day' '2024-03-10 12:00 EDT' '2024-03-10 12:00 EST' '2024-07-01 12:00 EST' '2024-01-01 12:00 EDT' '2024-07-01 12:00 DST' '2024-01-01 12:00 DST'; do
    for tzv in America/New_York Europe/London Australia/Sydney; do
        TZ=$tzv run_cmp "dst '$s' $tzv" -d "$s" '+%s %F %T %Z %z'
    done
done

printf "\n[ Current time and relative anchors ]\n"
for s in now today tomorrow yesterday 'next week' 'last week' 'next month' 'last month' 'next year' 'last year' 'next friday' 'last monday' 'friday' '3 days ago' '3 days' '-3 days' '+3 days' '3 weeks' '2 fortnights' '1 year ago' '3 months ago' '1 hour' '90 minutes' '30 sec' '1 sec ago' '1 min' '1.5 seconds' '-1.5 seconds' '+2.25 sec' '2 days 3 hours' '2 days 3 hours ago' '1 day 1 day' '+1 week' '1 fortnight' 'this friday' 'sunday' '2 days'; do
    run_cmp "date-only '$s'" -d "$s" +%F
    TZ=Asia/Kolkata run_cmp "date-only '$s' IST" -d "$s" +%F
done
for s in 'tomorrow noon' 'today 15:00' 'yesterday 3pm' 'next friday 12:00' 'monday 00:00' 'noon' 'midnight' '12:00' '1am' '23:59:59'; do
    run_cmp "time '$s'" -d "$s" '+%F %T'
done

printf "\n[ -f ]\n"
printf '2024-01-01\n2024-02-29 12:00\n@5\nnonsense\n\n2024-05-05 +1 day\n' > dates
run_cmp "-f file"             -f dates '+%s'
run_cmp "-f file TZ"          -f dates '+%s %Z'
TZ=Asia/Kolkata run_cmp "-f file IST" -f dates '+%F %T'
CMP_STDIN=dates run_cmp "-f -"       -f - '+%s'
run_cmp "-f missing"          -f nofile
run_cmp "-f and -d"           -f dates -d @0
run_cmp "-f empty"            -f /dev/null

printf "\n[ -r and mutually exclusive options ]\n"
printf x > ref; touch -d @1000000000 ref
run_cmp "-r"                  -r ref '+%s'
run_cmp "-r default fmt"      -r ref
TZ=America/New_York run_cmp "-r NY" -r ref
run_cmp "-r missing"          -r nofile
run_cmp "-r and -d"           -r ref -d @0
run_cmp "-d and -d"           -d @1 -d @2 '+%s'
run_cmp "--resolution and -d" --resolution -d @0
run_cmp "-s and -d"           -s '2000-01-01' -d @0

printf "\n[ Setting the clock and operands ]\n"
run_cmp "-s without privilege"  -s '2030-01-01 00:00:00' '+%Y'
run_cmp "-s invalid"            -s garbage
run_cmp "posix 010112002030"    010112002030 '+%s'
run_cmp "posix MMDDhhmm"        01011200 '+%m%d%H%M'
run_cmp "posix with year"       0101120030 '+%Y'
run_cmp "posix with ss"         010112002030.45 '+%S'
run_cmp "posix bad"             13011200
run_cmp "posix bad day"         02301200
run_cmp "posix short"           0101
run_cmp "operand no plus -d"    -d @0 abc
run_cmp "extra operand"         +%Y +%m
run_cmp "format plus only"      +
run_cmp "empty format"          -d @0 +
run_cmp "bad option"            -x
run_cmp "long abbrev"           --ut -d @0
run_cmp "ambiguous"             --r -d @0
run_cmp "-d needs arg"          -d
run_cmp "--date="               --date=@5 +%s
run_cmp "--date @arg"           --date @5 +%s

printf "\n[ Random date strings ]\n"
LC_ALL=C awk 'BEGIN{srand(101);
 n_d=split("2024-02-29|2023-12-31|2000-01-01|1999-07-04|2038-01-19|2024/03/10|03/10/2024|Mar 10 2024|10 March 2024|20240310|1970-01-01|2024-11-03|2024-03-31|2025-01-31", D, "|");
 n_t=split("12:00|00:00:00|23:59:59|1:30|7pm|11:30 am|12:15:20.5|noon|00:30|02:30|01:30", T, "|");
 n_z=split("UTC|EST|EDT|+0100|-0530|Z|CET|PST|+01:00|UTC+2", Z, "|");
 n_r=split("+1 day|-1 day|1 week ago|2 months|3 years ago|36 hours|90 min|1 fortnight|next monday|last friday|this sunday|tomorrow|yesterday|5 days|+1 month|-1 year|2 weeks ago|1 sec", R, "|");
 for(i=0;i<1200;i++){ s=""; if(rand()<0.85) s=s D[1+int(rand()*n_d)]; if(rand()<0.6) s=s " " T[1+int(rand()*n_t)]; if(rand()<0.25) s=s " " Z[1+int(rand()*n_z)]; k=int(rand()*3); for(j=0;j<k;j++) s=s " " R[1+int(rand()*n_r)]; if (s !~ /[0-9]{4}|[0-9]:[0-9]/) s="2024-02-29 " s; sub(/^ /,"",s); print s }}' > rnd
while IFS= read -r line; do
    run_cmp "rnd '$line' UTC" -u -d "$line" '+%s.%N'
    TZ=America/New_York run_cmp "rnd '$line' NY" -d "$line" '+%s %F %T %Z'
done < rnd

print_summary
[ "$FAIL" -eq 0 ]
