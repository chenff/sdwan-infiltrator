local comm = require "comm"
local string = require "string"
local table = require "table"
local shortport = require "shortport"
local nmap = require "nmap"
local stdnse = require "stdnse"
local U = require "lpeg-utility"
local http = require "http"
local snmp = require "snmp"
local sslcert = require "sslcert"
local tls = require "tls"
local url = require "url"

description = [[
Search SD-WAN products from SDWAN NewHope research project database by
- server name
- http titles
- snmp descriptions
- ssl certificates

The search database is based on census.md document with SD-WAN products search queries.
Also this script is based on:
- http-server-header NSE script by Daniel Miller
- http-title NSE script by Diman Todorov
- snmp-sysdescr NSE script by Thomas Buchanan
- ssl-cert NSE script by David Fifield
]]


-- 
-- @usage
-- nmap --script=infiltrator.nse -sS -sU -p U:161,T:80,443 <target> or -iL <targets.txt>
-- 
-- @output
-- | infiltrator:
-- |   status: success
-- |   method: server
-- |   product: <product name>
-- |   host_addr: ...
-- |   host_port: 443
-- |_  version: ...
-- ...
-- | infiltrator:
-- |   status: success
-- |   method: title
-- |   product: <product name>
-- |   host_addr: ...
-- |   host_port: 443
-- |_  version: ...
-- ...
-- | infiltrator:
-- |   status: success
-- |   method: snmp
-- |   product: <product name>
-- |   host_addr: ...
-- |   host_port: 161
-- |_  version: ...
-- ...
-- | infiltrator:
-- |   status: success
-- |   method: SSL certificate
-- |   product: <product name>
-- |   host_addr: ...
-- |   host_port: 443
-- |_  version: ...


author = "sdnewhop"
license = "Same as Nmap--See https://nmap.org/book/man-legal.html"
categories = {"default", "discovery", "safe"}


portrule = shortport.portnumber({80, 161, 443}, {"tcp", "udp"}, {"open"})

SDWANS_BY_SSL_TABLE = {
  ["Cisco SD-WAN"] = {"Viptela Inc"},
  ["Versa Analytics"] = {"versa%-analytics"},
  ["Versa Director"] = {"director%-1", "versa%-director"},
  ["Riverbed SteelHead"] = {"Riverbed Technology"},
  ["Silver Peak Unity Orchestrator"] = {"Silverpeak GMS"},
  ["Silver Peak Unity EdgeConnect"] = {"silver%-peak", "Silver Peak Systems Inc"},
  ["CloudGenix SD-WAN"] = {"CloudGenix Inc."},
  ["Talari SD-WAN"] = {"Talari", "Talari Networks"},
  ["InfoVista SALSA"] = {"SALSA Portal"},
  ["Barracuda CloudGen Firewall"] = {"Barracuda CloudGen Firewall", "Barracuda Networks"},
  ["Viprinet Virtual VPN Hub"] = {"Viprinet"},
  ["Citrix Netscaler SD-WAN"] = {"Citrix Systems"},
  ["Fortinet FortiGate SD-WAN"] = {"FGT%-", "FortiGate"}
}

SDWANS_BY_SNMP_TABLE = {
    ["Fatpipe SYMPHONY SD-WAN"] = {"Linux Fatpipe"},
    ["Versa Analytics"] = {"Linux versa%-analytics"},
    ["Juniper Networks Contrail SD-WAN"] = {"Juniper Networks, Inc. srx"},
    ["Aryaka Network Access Point"] = {"Aryaka Networks Access Point"},
    ["Arista Networks EOS"] = {"Arista Networks EOS"},
    ["Viprinet Virtual VPN Hub"]= {"Viprinet VPN Router"}
}

SDWANS_BY_TITLE_TABLE = {
    ["VMWare NSX SD-WAN"] = {"VeloCloud", "VeloCloud Orchestrator"},
    ["TELoIP VINO SD-WAN"] = {"Teloip Orchestrator API"},
    ["Fatpipe SYMPHONY SD-WAN"] = {"WARP"},
    ["Cisco SD-WAN"] = {"Viptela vManage", "Cisco vManage"},
    ["Versa Flex VNF"] = {"Flex VNF"},
    ["Versa Director"] = {"Versa Director Login"},
    ["Riverbed SteelConnect"] = {"SteelConnect Manager", "Riverbed AWS Appliance"},
    ["Riverbed SteelHead"] = {"amnesiac Sign in"},
    ["Citrix NetScaler SD-WAN VPX"] = {"Citrix NetScaler SD%-WAN %- Login"},
    ["Citrix NetScaler SD-WAN Center"] = {"SD%-WAN Center | Login"},
    ["Citrix Netscaler SD-WAN"] = {"DC | Login"},
    ["Silver Peak Unity Orchestrator"] = {"Welcome to Unity Orchestrator"},
    ["Silver Peak Unity EdgeConnect"] = {"Silver Peak Appliance Management Console"},
    ["Ecessa WANworX SD-WAN"] = {"Ecessa"},
    ["Nuage Networks SD-WAN (VNS)"] = {"SD%-WAN Portal", "Architect", "VNS portal"}, 
    ["Juniper Networks Contrail SD-WAN"] = {"Log In %- Juniper Networks Web Management"},
    ["Talari SD-WAN"] = {"AWS"},
    ["Aryaka Network Access Point"] = {"Aryaka Networks", "Aryaka, Welcome"},
    ["InfoVista SALSA"] = {"SALSA Login"},
    ["Huawei SD-WAN"] = {"Agile Controller"},
    ["Sonus SBC Management Application"] = {"SBC Management Application"},
    ["Sonus SBC Edge"] = {"Sonus SBC Edge Web Interface"},
    ["Arista Networks EOS"] = {"Arista Networks EOS"},
    ["128 Technology Networking Platform"] = {"128T Networking Platform"},
    ["Gluware Control"] = {"Gluware Control"},
    ["Barracuda CloudGen Firewall"] = {"Barracuda CloudGen Firewall"},
    ["Viprinet Virtual VPN Hub"] = {"Viprinet %- AdminDesk %- Login"},
    ["Viprinet Traffic Tools"] = {"Viprinet traffic tools"},
    ["Cradlepoint SD-WAN"] = {"Login :: CR4250%-PoE", "Login :: AER2200%-600M"},
    ["Brain4Net Orchestrator"] = {"B4N ORC"}
  }

SDWANS_BY_SERVER_TABLE = {
      ["Versa Director"] = {"Versa Director"},
      ["Barracuda CloudGen Firewall"] = {"Barracuda CloudGen Firewall"},
      ["Viprinet Virtual VPN Hub"] = {"ViprinetHubReplacement", "Viprinet"}
  }

-------------------------------------------------------------------------------
-- version gathering block
-------------------------------------------------------------------------------

local function vbrain(host, port)
  local path = stdnse.get_script_args(SCRIPT_NAME .. ".path") or "/api/version"
  local response
  local output_info = {}
  local vsdwan = ""
  local urlp = path

  response = http.generic_request(host, port, "GET", path)

  if response.status == 301 or response.status == 302 then
    local url_parse_res = url.parse(response.header.location)
    urlp = url_parse_res.path
    stdnse.print_debug("Status code: " .. response.status)
    response = http.generic_request(host,port,"GET", urlp)
  end

  output_info = stdnse.output_table()

  if response == nil then
    return fail("Request failed")
  end

  local try_counter = 1

  while try_counter < 6 and response.status ~= 200 do
    response = http.generic_request(host, port, "GET", urlp) 

    found, matches = http.response_contains(response, '0;url%=(.*)"%/%>')

    if found == true then 
      local urltmp = url.parse(matches[1])
      urlp = urltmp.path
      response = http.generic_request(host, port, "GET", urlp)
      try_counter = 1
    end
    try_counter = try_counter + 1
  end

  if response.status == 200 then

    found, matches = http.response_contains(response, '"build":"(.+)",', false)
    if found == true then vsdwan = matches[1] else return nil end
    
    output_info.vsdwan_version = {}
    table.insert(output_info.vsdwan_version, "Brain4Net Orchestrator Version: " .. vsdwan)
  end

  return output_info, stdnse.format_output(true, output_info)
end

local function vcradlepoint(host, port)
  local path = stdnse.get_script_args(SCRIPT_NAME .. ".path") or "/login/?referer=/admin/"
  local response
  local output_info = {}
  local vsdwan = ""
  local urlp = path

  response = http.generic_request(host, port, "GET", path)

  if response.status == 301 or response.status == 302 then
    local url_parse_res = url.parse(response.header.location)
    urlp = url_parse_res.path
    stdnse.print_debug("Status code: " .. response.status)
    response = http.generic_request(host,port,"GET", urlp)
  end

  output_info = stdnse.output_table()

  if response == nil then
    return fail("Request failed")
  end

  local try_counter = 1

  while try_counter < 6 and response.status ~= 200 do
    response = http.generic_request(host, port, "GET", urlp) 
    try_counter = try_counter + 1
  end

  if response.status == 200 then
    found, matches = http.response_contains(response, "([0-9.]+[0-9]) .[a-zA-Z]+.[a-zA-Z]+.[0-9]+.[0-9]+:[0-9]+:[0-9]+", false)
    if found == true then vsdwan = matches[1] else return nil end
    
    output_info.vsdwan_version = {}
    table.insert(output_info.vsdwan_version, "Cradlepoint App Version: " .. vsdwan)
  end

  return output_info, stdnse.format_output(true, output_info)
end

local function vcitrix(host, port)
  local path = stdnse.get_script_args(SCRIPT_NAME .. ".path") or "/"
  local response
  local output_info = {}
  local vsdwan = ""
  local urlp = path
  response = http.generic_request(host, port, "GET", path)
  if response.status == 301 or response.status == 302 then
    local url_parse_res = url.parse(response.header.location)
    urlp = url_parse_res.path
    -- stdnse.print_debug("Status code: " .. response.status)
    response = http.generic_request(host,port,"GET", urlp)
  end

  output_info = stdnse.output_table()
  if response == nil then
    return fail("Request failed")
  end

  local try_counter = 1
  while try_counter < 30 and response.status ~= 200 do
    response = http.generic_request(host, port, "GET", urlp) 
    try_counter = try_counter + 1
  end

  if response.status == 200 then
    found, matches = http.response_contains(response, "css%?v%=([.0-9]+)", false)
    if found == true then vsdwan = matches[1] else return nil end
    output_info.vsdwan_version = {}
    table.insert(output_info.vsdwan_version, "Citrix NetScaler Version: " .. vsdwan)
  end

  return output_info, stdnse.format_output(true, output_info)

end


local function vfatpipe(host, port)
  local path = stdnse.get_script_args(SCRIPT_NAME .. ".path") or "/"
  local response
  local output_info = {}
  local vsdwan = ""
  local urlp = path

  response = http.generic_request(host, port, "GET", path)

  if response.status == 301 or response.status == 302 then
    local url_parse_res = url.parse(response.header.location)
    urlp = url_parse_res.path
    stdnse.print_debug("Status code: " .. response.status)
    response = http.generic_request(host,port,"GET", urlp)
  end

  output_info = stdnse.output_table()

  if response == nil then
    return fail("Request failed")
  end

  local try_counter = 1

  while try_counter < 6 and response.status ~= 200 do
    response = http.generic_request(host, port, "GET", urlp) 
    try_counter = try_counter + 1
  end

  if response.status == 200 then

    found, matches = http.response_contains(response, "<h5>([r.0-9]+)</h5>", false)
    if found == true then vsdwan = matches[1] else return nil end
    
    output_info.vsdwan_version = {}
    table.insert(output_info.vsdwan_version, "Fatpipe Version: " .. vsdwan)
  end

  return output_info, stdnse.format_output(true, output_info)

end


local function vnuage(host, port)
  local path = stdnse.get_script_args(SCRIPT_NAME .. ".path") or "/"
  local response
  local output_info = {}
  local vsdwan = ""
  local urlp = path

  response = http.generic_request(host, port, "GET", path)

  if response.status == 301 or response.status == 302 then
    local url_parse_res = url.parse(response.header.location)
    urlp = url_parse_res.path
    stdnse.print_debug("Status code: " .. response.status)
    response = http.generic_request(host,port,"GET", urlp)
  end

  output_info = stdnse.output_table()

  if response == nil then
    return fail("Request failed")
  end

  local try_counter = 1

  while try_counter < 6 and response.status ~= 200 do
    response = http.generic_request(host, port, "GET", urlp) 
    try_counter = try_counter + 1
  end

  if response.status == 200 then

    found, matches = http.response_contains(response, 'ng%-version="([.0-9]+)"', false)
    if found == true then vsdwan = matches[1] else return nil end
    
    output_info.vsdwan_version = {}
    table.insert(output_info.vsdwan_version, "Nuage Version: " .. vsdwan)
  end

  return output_info, stdnse.format_output(true, output_info)

end


local function vriverbed(host, port)
  local path = stdnse.get_script_args(SCRIPT_NAME .. ".path") or "/"
  local response
  local output_info = {}
  local vsdwan = ""
  local urlp = path

  response = http.generic_request(host, port, "GET", path)

  if response.status == 301 or response.status == 302 then
    local url_parse_res = url.parse(response.header.location)
    urlp = url_parse_res.path
    stdnse.print_debug("Status code: " .. response.status)
    response = http.generic_request(host,port,"GET", urlp)
  end

  output_info = stdnse.output_table()

  if response == nil then
    return fail("Request failed")
  end

  local try_counter = 1

  while try_counter < 6 and response.status ~= 200 do
    response = http.generic_request(host, port, "GET", urlp) 
    try_counter = try_counter + 1
  end

  if response.status == 200 then

    found, matches = http.response_contains(response, "web3 v([.0-9]+)", false)
    if found == true then vsdwan = matches[1] else return nil end
    
    output_info.vsdwan_version = {}
    table.insert(output_info.vsdwan_version, "Riverbed Version: " .. vsdwan)
  end

  return output_info, stdnse.format_output(true, output_info)

end


local function vsilverpeak(host, port)
  local path = stdnse.get_script_args(SCRIPT_NAME .. ".path") or "/"
  local response
  local output_info = {}
  local vsdwan = ""
  local urlp = path

  response = http.generic_request(host, port, "GET", path)

  output_info = stdnse.output_table()

  if response == nil then
    return fail("Request failed")
  end

  if response.status == 302 then

    found, matches = http.response_contains(response, "http.*/([.0-9]+)/", false)
    if found == true then vsdwan = matches[1] else return nil end
    
    output_info.vsdwan_version = {}
    table.insert(output_info.vsdwan_version, "SilverPeak Version: " .. vsdwan)
  end

  return output_info, stdnse.format_output(true, output_info)

end


local function vsonus_edge(host, port)
  local path = stdnse.get_script_args(SCRIPT_NAME .. ".path") or "/cgi/index.php"
  local response
  local output_info = {}
  local vsdwan = ""
  local urlp = path

  response = http.generic_request(host, port, "GET", path)

  if response.status == 301 or response.status == 302 then
    local url_parse_res = url.parse(response.header.location)
    urlp = url_parse_res.path
    stdnse.print_debug("Status code: " .. response.status)
    response = http.generic_request(host,port,"GET", urlp)
  end

  output_info = stdnse.output_table()

  if response == nil then
    return fail("Request failed")
  end

  local try_counter = 1

  while try_counter < 6 and response.status ~= 200 do
    response = http.generic_request(host, port, "GET", urlp) 
    try_counter = try_counter + 1
  end

  if response.status == 200 then

    found, matches = http.response_contains(response, "/style/([.0-9]+)%-[0-9]+%_rel", false)
    if found == true then vsdwan = matches[1] else return nil end
    
    output_info.vsdwan_version = {}
    table.insert(output_info.vsdwan_version, "Sonus Edge Version: " .. vsdwan)
  end

  return output_info, stdnse.format_output(true, output_info)

end


local function vsonus_mgmt(host, port)
  local path = stdnse.get_script_args(SCRIPT_NAME .. ".path") or "/"
  local response
  local output_info = {}
  local vsdwan = ""
  local urlp = path

  response = http.generic_request(host, port, "GET", path)

  if response.status == 301 or response.status == 302 then
    local url_parse_res = url.parse(response.header.location)
    urlp = url_parse_res.path
    stdnse.print_debug("Status code: " .. response.status)
    response = http.generic_request(host,port,"GET", urlp)
  end

  output_info = stdnse.output_table()

  if response == nil then
    return fail("Request failed")
  end

  local try_counter = 1

  while try_counter < 6 and (response.status ~= 503 or response.status ~= 200) do
    response = http.generic_request(host, port, "GET", urlp) 
    try_counter = try_counter + 1
  end

  if response.status == 503 or response.status == 200 then

    found, matches = http.response_contains(response, "EMA ([.0-9]+)", false)
    if found == true then vsdwan = matches[1] else return nil end
    
    output_info.vsdwan_version = {}
    table.insert(output_info.vsdwan_version, "Sonus Mgmt App Version: " .. vsdwan)
  end

  return output_info, stdnse.format_output(true, output_info)

end


local function vtalari(host, port)
  local path = stdnse.get_script_args(SCRIPT_NAME .. ".path") or "/"
  local response
  local output_info = {}
  local vsdwan = ""
  local urlp = path

  response = http.generic_request(host, port, "GET", path)

  if response.status == 301 or response.status == 302 then
    local url_parse_res = url.parse(response.header.location)
    urlp = url_parse_res.path
    stdnse.print_debug("Status code: " .. response.status)
    response = http.generic_request(host,port,"GET", urlp)
  end

  output_info = stdnse.output_table()

  if response == nil then
    return fail("Request failed")
  end

  local try_counter = 1

  while try_counter < 6 and response.status ~= 200 do
    response = http.generic_request(host, port, "GET", urlp) 
    try_counter = try_counter + 1
  end

  if response.status == 200 then

    found, matches = http.response_contains(response, 'talari%.css%?([_.0-9A-Za-z]+)"', false)
    if found == true then vsdwan = matches[1] else return nil end
    
    output_info.vsdwan_version = {}
    table.insert(output_info.vsdwan_version, "Talari Version: " .. vsdwan)
  end

  return output_info, stdnse.format_output(true, output_info)

end


local function vversa_analytics(host, port)
  local path = stdnse.get_script_args(SCRIPT_NAME .. ".path") or "/versa/app/js/common/constants.js"
  local response
  local output_info = {}
  local vsdwan = ""
  local urlp = path

  response = http.generic_request(host, port, "GET", path)

  if response.status == 301 or response.status == 302 then
    local url_parse_res = url.parse(response.header.location)
    urlp = url_parse_res.path
    stdnse.print_debug("Status code: " .. response.status)
    response = http.generic_request(host,port,"GET", urlp)
  end

  output_info = stdnse.output_table()

  if response == nil then
    return fail("Request failed")
  end

  local try_counter = 1

  while try_counter < 6 and response.status ~= 200 do
    response = http.generic_request(host, port, "GET", urlp) 

    found, matches = http.response_contains(response, '0;url%=(.*)"%/%>')

    if found == true then 
      local urltmp = url.parse(matches[1])
      urlp = urltmp.path
      response = http.generic_request(host, port, "GET", urlp)
      try_counter = 1
    end
    try_counter = try_counter + 1
  end

  if response.status == 200 then

    found, matches = http.response_contains(response, "%/analytics%/([v.0-9]+)%/", false)
    if found == true then vsdwan = matches[1] else return nil end
    
    output_info.vsdwan_version = {}
    table.insert(output_info.vsdwan_version, "Versa Analytics Version: " .. vsdwan)
  end

  return output_info, stdnse.format_output(true, output_info)

end


local function vversa_flex(host, port)
  local path = stdnse.get_script_args(SCRIPT_NAME .. ".path") or "/scripts/main-layout/main-layout-controller.js"
  local response
  local output_info = {}
  local vsdwan = ""
  local urlp = path

  response = http.generic_request(host, port, "GET", path)

  if response.status == 301 or response.status == 302 then
    local url_parse_res = url.parse(response.header.location)
    urlp = url_parse_res.path
    stdnse.print_debug("Status code: " .. response.status)
    response = http.generic_request(host,port,"GET", urlp)
  end

  output_info = stdnse.output_table()

  if response == nil then
    return fail("Request failed")
  end

  local try_counter = 1

  while try_counter < 6 and response.status ~= 200 do
    response = http.generic_request(host, port, "GET", urlp) 
    try_counter = try_counter + 1
  end

  if response.status == 200 then

    found, matches = http.response_contains(response, '"versa%-flexvnf%-([.0-9%-a-zA-Z]+)', false)
    if found == true then vsdwan = matches[1] else return nil end
    
    output_info.vsdwan_version = {}
    table.insert(output_info.vsdwan_version, "Versa Flex Version: " .. vsdwan)
  end

  return output_info, stdnse.format_output(true, output_info)

end


local function vvmware_nsx(host, port)
  local path = stdnse.get_script_args(SCRIPT_NAME .. ".path") or "/"
  local response
  local output_info = {}
  local vsdwan = ""
  local urlp = path

  response = http.generic_request(host, port, "GET", path)

  if response.status == 301 or response.status == 302 then
    local url_parse_res = url.parse(response.header.location)
    urlp = url_parse_res.path
    stdnse.print_debug("Status code: " .. response.status)
    response = http.generic_request(host,port,"GET", urlp)
  end

  output_info = stdnse.output_table()

  if response == nil then
    return fail("Request failed")
  end

  local try_counter = 1

  while try_counter < 6 and response.status ~= 200 do
    response = http.generic_request(host, port, "GET", urlp) 
    try_counter = try_counter + 1
  end

  if response.status == 200 then

    found, matches = http.response_contains(response, "%/vco%-ui.([0-9.]+).", false)
    if found == true then vsdwan = matches[1] else return nil end
    
    output_info.vsdwan_version = {}
    table.insert(output_info.vsdwan_version, "VMware NSX Version: " .. vsdwan)
  end

  return output_info, stdnse.format_output(true, output_info)

end


-------------------------------------------------------------------------------
-- version functions call table
-------------------------------------------------------------------------------

VERSION_CALL_TABLE = {
  ["Citrix NetScaler SD-WAN VPX"] = {version = vcitrix},
  ["Citrix NetScaler SD-WAN Center"] = {version = vcitrix},
  ["Citrix Netscaler SD-WAN"] = {version = vcitrix},
  ["Fatpipe SYMPHONY SD-WAN"] = {version = vfatpipe},
  ["Nuage Networks SD-WAN (VNS)"] = {version = vnuage},
  ["Riverbed SteelHead"] = {version = vriverbed},
  ["Riverbed SteelConnect"] = {version = vriverbed},
  ["Silver Peak Unity Orchestrator"] = {version = vsilverpeak},
  ["Silver Peak Unity EdgeConnect"] = {version = vsilverpeak},
  ["Sonus SBC Management Application"] = {version = vsonus_mgmt},
  ["Sonus SBC Edge"] = {version = vsonus_edge},
  ["Talari SD-WAN"] = {version = vtalari},
  ["Versa Analytics"] = {version = vversa_analytics},
  ["Versa Flex VNF"] = {version = vversa_flex},
  ["VMWare NSX SD-WAN"] = {version = vvmware_nsx},
  ["Cradlepoint SD-WAN"] = {version = vcradlepoint},
  ["Brain4Net Orchestrator"] = {version = vbrain}
}

-------------------------------------------------------------------------------
-------------------------------------------------------------------------------

local function get_version(product, host, port)
  local version = nil
  for version_product, _ in pairs(VERSION_CALL_TABLE) do
    -- check if product in version list
    if version_product == product then
        version = VERSION_CALL_TABLE[product].version(host, port)
    end
  end
  return version
end

local function ssl_name_to_table(name)
  local output = {}
  for k, v in pairs(name) do
    if type(k) == "table" then
      k = stdnse.strjoin(".", k)
    end
    output[k] = v
  end
  return output
end


local function collect_results(status, method, product, addr, port, version)
  local output_tab = stdnse.output_table()
  output_tab.status = status
  output_tab.method = method
  output_tab.product = product
  output_tab.host_addr = addr
  output_tab.host_port = port
  if version ~= nil then
    if version['vsdwan_version'] ~= nil then
      parse = version['vsdwan_version'][1]
      output_tab.version = string.match(parse, ': (.*)')
    end
  end
  return output_tab
end


local function check_ssl(host, port, version_arg)
  if not (shortport.ssl(host, port) or sslcert.isPortSupported(port) or sslcert.getPrepareTLSWithoutReconnect(port)) then
    return nil
  end

  local cert_status, cert = sslcert.getCertificate(host, port)
  if not cert_status then
    return nil
  end
  
  ssl_subject = ssl_name_to_table(cert.subject)
  if not ssl_subject then
    return nil
  end 

  for product, titles in pairs(SDWANS_BY_SSL_TABLE) do
    for _, sd_wan_title in ipairs(titles) do
      for _, ssl_field in pairs(ssl_subject) do
        if string.match(ssl_field:lower(), sd_wan_title:lower()) then
          stdnse.print_debug("Matched SSL certificates: " .. ssl_field)
          local version = nil
          if version_arg then
            version = get_version(product, host, port)
          end
          return collect_results("success", "SSL certificate", product, host.ip, port.number, version)
        end
      end
    end
  end
end


local function check_snmp(host, port, version_arg)
  if not shortport.portnumber(161, "udp", {"open"}) then
    return nil
  end

  local snmpHelper = snmp.Helper:new(host, port)
  snmpHelper:connect()

  local status, response = snmpHelper:get({reqId=28428}, "1.3.6.1.2.1.1.1.0")
  if not status then
    return nil
  end

  nmap.set_port_state(host, port, "open")
  local result = response and response[1] and response[1][1]
  if not result then
    return nil
  end

  for product, titles in pairs(SDWANS_BY_SNMP_TABLE) do
    for _, sd_wan_title in ipairs(titles) do
      if string.match(result:lower(), sd_wan_title:lower()) then
        stdnse.print_debug("Matched SNMP banners: " .. product)
        -- override snmp port
        local version = nil
        if version_arg then
          if product == "Versa Analytics" then
            version = get_version(product, host, 8080)
          end
          if not version then
            version = get_version(product, host, 80)
          end
        end
        return collect_results("success", "snmp banner", product, host.ip, port.number, version)
      end
    end
  end
end


local function check_title(host, port, version_arg)
  if not shortport.http(host, port) then
    return nil
  end

  local resp = http.get(host, port, "/")

  --make redirect if needed
  if resp.status == 301 or resp.status == 302 then
    local url = url.parse( resp.header.location )
    if url.host == host.targetname or url.host == ( host.name ~= '' and host.name ) or url.host == host.ip then
      stdnse.print_debug("Redirect: " .. host.ip .. " -> " .. url.scheme.. "://" .. url.authority .. url.path)
      resp = http.get(url.authority, 443, "/")
    end
  end

  if not resp.body then
    return nil
  end

  local title = string.match(resp.body, "<[Tt][Ii][Tt][Ll][Ee][^>]*>([^<]*)</[Tt][Ii][Tt][Ll][Ee]>")
  if not title then
    return nil
  end
  stdnse.print_debug("Get title: " .. title)
  for product, titles in pairs(SDWANS_BY_TITLE_TABLE) do
    for _, sd_wan_title in ipairs(titles) do
      if string.match(title:lower(), sd_wan_title:lower()) then
        stdnse.print_debug("Matched titles: " .. title)
        local version = nil
        if version_arg then
          version = get_version(product, host, port)
        end
        return collect_results("success", "http-title", product, host.ip, port.number, version)
      end
    end
  end
end


local function check_server(host, port, version_arg)
  if not (shortport.http(host, port) and nmap.version_intensity() >= 7) then
    return nil
  end

  local responses = {}
  if port.version and port.version.service_fp then
    for _, p in ipairs({"GetRequest", "GenericLines", "HTTPOptions",
      "FourOhFourRequest", "NULL", "RTSPRequest", "Help", "SIPOptions"}) do
      responses[#responses+1] = U.get_response(port.version.service_fp, p)
    end
  end

  if #responses == 0 then
    local socket, result = comm.tryssl(host, port, "GET / HTTP/1.0\r\n\r\n")

    if not socket then
      return nil
    end

    socket:close()
    responses[1] = result
  end

  -- Also send a probe with host header if we can. IIS reported to send
  -- different Server headers depending on presence of Host header.
  local socket, result = comm.tryssl(host, port,
    ("GET / HTTP/1.1\r\nHost: %s\r\n\r\n"):format(stdnse.get_hostname(host)))
  if socket then
    socket:close()
    responses[#responses+1] = result
  end

  port.version = port.version or {}

  local headers = {}
  for _, result in ipairs(responses) do
    if string.match(result, "^HTTP/1.[01] %d%d%d") then
      port.version.service = "http"

      local http_server = string.match(result, "\n[Ss][Ee][Rr][Vv][Ee][Rr]:[ \t]*(.-)\r?\n")

      -- Avoid setting version info if -sV scan already got a match
      if port.version.product == nil and (port.version.name_confidence or 0) <= 3 then
        port.version.product = http_server
      end

      -- Setting "softmatched" allows the service fingerprint to be printed
      nmap.set_port_version(host, port, "softmatched")

      if http_server then
        headers[http_server] = true
      end
    end
  end

  for product, servers in pairs(SDWANS_BY_SERVER_TABLE) do
    for _, sd_wan_server in ipairs(servers) do
      for recv_server, _ in pairs(headers) do
        if string.match(recv_server:lower(), sd_wan_server:lower()) then
          stdnse.print_debug("Matched servers: " .. recv_server)
          local version = nil
          if version_arg then
            version = get_version(product, host, port)
          end
          return collect_results("success", "http-server", product, host.ip, port.number, version)
        end
      end
    end
  end
end 


action = function(host, port)
  version_arg = stdnse.get_script_args(SCRIPT_NAME..".version") or "false"
  if version_arg == "true" then
    version_arg = true
  else
    version_arg = false
  end

  -- get title and server from http/https
  if (port.number == 443 or port.number == 80) then
    local title_tab = check_title(host, port, version_arg)
    if title_tab then
      return title_tab
    end

    local server_tab = check_server(host, port, version_arg)
    if server_tab then
      return server_tab
    end

  -- check ssl cert from https
  if port.number == 443 then
    local ssl_tab = check_ssl(host, port, version_arg)
    if ssl_tab then
      return ssl_tab
    end
  end

  -- get snmp banner by 161 udp
  elseif port.number == 161 then
    local snmp_tab = check_snmp(host, port, version_arg)
    if snmp_tab then
      return snmp_tab
    end
  end
end