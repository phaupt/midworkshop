#!/bin/sh
# mobileid-query.sh
#
# Generic script using curl to invoke Swisscom Mobile ID service to
# query details about MSISDN.
# Dependencies: curl, sed, date, xmllint, python
#
# License: Licensed under the Apache License, Version 2.0 or later; see LICENSE.md
# Author: Swisscom (Schweiz) AG
#

# set current working path to the path of the script
cd "$(dirname "$0")"

# Read configuration from property file
. ./mobileid.properties

# Error function
error()
{
  [ "$VERBOSE" = "1" -o "$DEBUG" = "1" ] && echo "$@" >&2
  exit 1
}

# Check command line
MSGTYPE=SOAP                                    # Default is SOAP
DEBUG=
VERBOSE=
while getopts "dvt:" opt; do                    # Parse the options
  case $opt in
    t) MSGTYPE=$OPTARG ;;                       # Message Type
    d) DEBUG=1 ;;                               # Debug
    v) VERBOSE=1 ;;                             # Verbose
  esac
done
shift $((OPTIND-1))                             # Remove the options

if [ $# -lt 1 ]; then                           # Parse the rest of the arguments
  echo "Usage: $0 <args> mobile"
  echo "  -t value   - message type (SOAP, JSON); default SOAP"
  echo "  -v         - verbose output"
  echo "  -d         - debug mode"
  echo "  mobile     - mobile number"
  echo
  echo "  Example $0 -v +41792080350"
  echo "          $0 -t JSON -v +41792080350"
  echo
  exit 1
fi

# Check the dependencies
for cmd in curl sed date xmllint python; do
  hash $cmd &> /dev/null
  if [ $? -eq 1 ]; then error "Dependency error: '$cmd' not found" ; fi
done

# Create temporary request
RANDOM=$$                                       # Seeds the random number generator from PID of script
AP_INSTANT=$(date +%Y-%m-%dT%H:%M:%S%:z)        # Define instant and transaction id
AP_TRANSID=AP.TEST.$((RANDOM%89999+10000)).$((RANDOM%8999+1000))
TMP=$(mktemp /tmp/_tmp.XXXXXX)                  # Request goes here
MSISDN=$1                                       # Destination phone number (MSISDN)
TIMEOUT=80                                      # Value of Timeout
TIMEOUT_CON=90                                  # Timeout of the client connection

case "$MSGTYPE" in
  # MessageType is SOAP. Define the Request
  SOAP)
    REQ_SOAP='<?xml version="1.0" encoding="UTF-8"?>
      <soapenv:Envelope
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xmlns:xsd="http://www.w3.org/2001/XMLSchema"
          soap:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"
          xmlns:soapenv="http://www.w3.org/2003/05/soap-envelope"
          xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
        <soapenv:Body>
          <MSS_ProfileQuery>
            <mss:MSS_ProfileReq MajorVersion="1" MinorVersion="1" xmlns:mss="http://uri.etsi.org/TS102204/v1.1.2#">
              <mss:AP_Info AP_PWD="'$AP_PWD'" AP_TransID="'$AP_TRANSID'" Instant="'$AP_INSTANT'" AP_ID="'$AP_ID'" />
              <mss:MSSP_Info>
                <mss:MSSP_ID>
                  <mss:URI>http://mid.swisscom.ch/</mss:URI>
                </mss:MSSP_ID>
              </mss:MSSP_Info>
              <mss:MobileUser>
                <mss:MSISDN>'$MSISDN'</mss:MSISDN>
              </mss:MobileUser>
            </mss:MSS_ProfileReq>
          </MSS_ProfileQuery>
        </soapenv:Body>
      </soapenv:Envelope>'
    # store into file
    echo "$REQ_SOAP" > $TMP.req ;;
    
  # MessageType is JSON. Define the Request
  JSON)
    REQ_JSON='{
        "MSS_ProfileReq": {
          "MajorVersion": "1",
          "MinorVersion": "1",
          "AP_Info": {
            "AP_ID": "'$AP_ID'",
            "AP_PWD": "'$AP_PWD'",
            "Instant": "'$AP_INSTANT'",
            "AP_TransID": "'$AP_TRANSID'"
          },
          "MSSP_Info": {
            "MSSP_ID": {
              "URI": "http://mid.swisscom.ch/"
            }
          },
          "MobileUser": {
            "MSISDN": "'$MSISDN'"
          }
        }
      }'
    # store into file
    echo "$REQ_JSON" > $TMP.req ;;
    
  # Unknown message type
  *)
    error "Unsupported message type $MSGTYPE, check with $0" ;;
    
esac

# Check existence of needed files
[ -r "${CERT_CA_SSL}" ] || error "CA certificate/chain file ($CERT_CA_SSL) missing or not readable"
[ -r "${CERT_KEY}" ]    || error "SSL key file ($CERT_KEY) missing or not readable"
[ -r "${CERT_FILE}" ]   || error "SSL certificate file ($CERT_FILE) missing or not readable"

# Define cURL Options according to Message Type
case "$MSGTYPE" in
  SOAP)
    URL=$BASE_URL/soap/services/MSS_ProfilePort
    HEADER_ACCEPT="Accept: application/xml"
    HEADER_CONTENT_TYPE="Content-Type: text/xml;charset=utf-8"
    TMP_REQ="--data @$TMP.req" ;;
  JSON)
    URL=$BASE_URL/rest/service
    HEADER_ACCEPT="Accept: application/json"
    HEADER_CONTENT_TYPE="Content-Type: application/json;charset=utf-8"
    TMP_REQ="--request POST --data-binary @$TMP.req" ;;
esac

# Call the service
http_code=$(curl --write-out '%{http_code}\n' $CURL_OPTIONS \
  $TMP_REQ \
  --header "${HEADER_ACCEPT}" --header "${HEADER_CONTENT_TYPE}" \
  --cert $CERT_FILE --cacert $CERT_CA_SSL --key $CERT_KEY \
  --output $TMP.rsp --trace-ascii $TMP.curl.log \
  --connect-timeout $TIMEOUT_CON \
  $URL)

# Results
RC=$?
if [ "$RC" = "0" -a "$http_code" -eq 200 ]; then
  case "$MSGTYPE" in
    SOAP)
      # Parse the response xml
      RES_RC=$(sed -n -e 's/.*<mss:StatusCode Value="\([^"]*\).*/\1/p' $TMP.rsp)
      RES_ST=$(sed -n -e 's/.*<mss:StatusMessage>\(.*\)<\/mss:StatusMessage>.*/\1/p' $TMP.rsp)
      ;;
    JSON)
      # Parse the response json
      RES_RC=$(sed -n -e 's/^.*"Value":"\([^"]*\)".*$/\1/p' $TMP.rsp)
      RES_ST=$(sed -n -e 's/^.*"StatusMessage":"\([^"]*\)".*$/\1/p' $TMP.rsp)
      ;;
  esac 
  
  # Status codes
  RC=1                                                          # By default not present
  if [ "$RES_RC" = "100" ]; then RC=0 ; fi                      # ACTIVE or REGISTERED user

  if [ "$VERBOSE" = "1" ]; then                                 # Verbose details
    echo "OK with following details and checks:"
    echo    " Status code    : $RES_RC with exit $RC"
    echo    " Status details : $RES_ST"
  fi
 else
  CURL_ERR=$RC                                                  # Keep related error
  RC=2                                                          # Force returned error code
  if [ "$VERBOSE" = "1" ]; then                                 # Verbose details
    [ $CURL_ERR != "0" ] && echo "curl failed with $CURL_ERR"   # Curl error
    if [ -s $TMP.rsp ]; then                                    # Response from the service
      case "$MSGTYPE" in
        SOAP)
          RES_VALUE=$(sed -n -e 's/.*<soapenv:Value>mss:_\(.*\)<\/soapenv:Value>.*/\1/p' $TMP.rsp)
          RES_REASON=$(sed -n -e 's/.*<soapenv:Text.*>\(.*\)<\/soapenv:Text>.*/\1/p' $TMP.rsp)
          RES_DETAIL=$(sed -n -e 's/.*<ns1:detail.*>\(.*\)<\/ns1:detail>.*/\1/p' $TMP.rsp)
          ;;
        JSON)
          RES_VALUE=$(sed -n -e 's/^.*"Value":"_\([^"]*\)".*$/\1/p' $TMP.rsp)
          RES_REASON=$(sed -n -e 's/^.*"Text":"\([^"]*\)".*$/\1/p' $TMP.rsp)
          RES_DETAIL=$(sed -n -e 's/^.*"Detail":"\([^"]*\)".*$/\1/p' $TMP.rsp)
          ;;
      esac
      echo "FAILED on $MSISDN with error $RES_VALUE ($RES_REASON: $RES_DETAIL) and exit $RC"
    fi
  fi
fi

# Debug details
if [ -n "$DEBUG" ]; then
  [ -f "$TMP.req" ] && echo ">>> $TMP.req <<<" && cat $TMP.req
  [ -f "$TMP.curl.log" ] && echo ">>> $TMP.curl.log <<<" && cat $TMP.curl.log | grep '==\|error'
  [ -f "$TMP.rsp" ] && echo ">>> $TMP.rsp <<<" && cat $TMP.rsp | ( [ "$MSGTYPE" != "JSON" ] && xmllint --format - || python -m json.tool ) 
fi

# Cleanups if not DEBUG mode
if [ "$DEBUG" = "" ]; then
  [ -f "$TMP" ] && rm $TMP
  [ -f "$TMP.req" ] && rm $TMP.req
  [ -f "$TMP.curl.log" ] && rm $TMP.curl.log
  [ -f "$TMP.rsp" ] && rm $TMP.rsp
fi

exit $RC

#==========================================================
