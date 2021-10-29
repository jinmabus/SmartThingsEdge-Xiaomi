local zcl_clusters = require "st.zigbee.zcl.clusters"
local capabilities = require "st.capabilities"

local OnOff = zcl_clusters.OnOff
local log = require "log"
local utils = require "utils"
local mgmt_bind_resp = require "st.zigbee.zdo.mgmt_bind_response"
local mgmt_bind_req = require "st.zigbee.zdo.mgmt_bind_request"
local zdo_messages = require "st.zigbee.zdo"
local data_types = require "st.zigbee.data_types"
local cluster_base = require "st.zigbee.cluster_base"
local xiaomi_utils = require "xiaomi_utils"
local device_management = require "st.zigbee.device_management"

local OnOff = zcl_clusters.OnOff
local PowerConfiguration = zcl_clusters.PowerConfiguration
local MultistateInput = 0x0012

local OPPLE_CLUSTER = 0xFCC0

local OPPLE_FINGERPRINTS = {
    { mfr = "LUMI", model = "lumi.switch.l1aeu1" },
    { mfr = "LUMI", model = "lumi.switch.l2aeu1" },
    { mfr = "LUMI", model = "lumi.remote.b286opcn01" },
    { mfr = "LUMI", model = "lumi.remote.b28ac1" },
    { mfr = "LUMI", model = "lumi.remote.b286acn01" }
}

local is_opple = function(opts, driver, device)
    for _, fingerprint in ipairs(OPPLE_FINGERPRINTS) do
        if device:get_manufacturer() == fingerprint.mfr and device:get_model() == fingerprint.model then
            return true
        end
    end
    return false
end


local function zdo_binding_table_handler(driver, device, zb_rx)
    log.warn("ZDO Binding Table Response")    
    if ~zb_rx.body.zdo_body.binding_table_entries then
      log.warn("No binding table entries")
      return
    end

    for _, binding_table in pairs(zb_rx.body.zdo_body.binding_table_entries) do
      if binding_table.dest_addr_mode.value == binding_table.DEST_ADDR_MODE_SHORT then
        -- send add hub to zigbee group command
        driver:add_hub_to_zigbee_group(binding_table.dest_addr.value)
      end
    end
end

local do_refresh = function(self, device)
    device:send(cluster_base.read_manufacturer_specific_attribute(device, OPPLE_CLUSTER, 0x0009, 0x115F))
end

local do_configure = function(self, device)
    local operationMode = device.preferences.operationMode or 0
    operationMode = tonumber(operationMode)

    log.info("Configuring Opple device " .. tostring(operationMode))

    -- data_types.id_to_name_map[0xE10] = "OctetString"
    -- data_types.name_to_id_map["SpecialType"] = 0xE10

    device:send(cluster_base.write_manufacturer_specific_attribute(device, OPPLE_CLUSTER, 0x0009, 0x115F, data_types.Uint8, operationMode) )

    if operationMode == 1 then -- hub
        OnOff:configure_reporting(device, 30, 3600) 
    elseif data == 0 then      -- bind
        device:send(device_management.build_bind_request(device, OnOff.ID, self.environment_info.hub_zigbee_eui))
        -- Read binding table
        local addr_header = messages.AddressHeader(
        constants.HUB.ADDR,
        constants.HUB.ENDPOINT,
        device:get_short_address(),
        device.fingerprinted_endpoint_id,
        constants.ZDO_PROFILE_ID,
        mgmt_bind_req.BINDING_TABLE_REQUEST_CLUSTER_ID
        )
        local binding_table_req = mgmt_bind_req.MgmtBindRequest(0) -- Single argument of the start index to query the table
        local message_body = zdo_messages.ZdoMessageBody({
                                                        zdo_body = binding_table_req
                                                    })
        local binding_table_cmd = messages.ZigbeeMessageTx({
                                                        address_header = addr_header,
                                                        body = message_body
                                                        })
        device:send(binding_table_cmd)
    end
end
  
local function info_changed(driver, device, event, args)
    log.info("info changed: " .. tostring(event))
    -- https://github.com/Koenkk/zigbee-herdsman-converters/blob/master/converters/toZigbee.js for more info
    for id, value in pairs(device.preferences) do
      if args.old_st_store.preferences[id] ~= value then --and preferences[id] then
        local data = tonumber(device.preferences[id])
        
        local attr
        local payload 
        
        if id == "operationMode" then
            do_configure(driver, device)
            --device:configure()
        elseif id == "powerOutageMemory" then
            payload = data_types.Boolean(value)
            attr = 0x0201
        elseif id == "ledDisabledNight" then
            payload = data_types.Boolean(value)
            attr = 0x0203
        elseif id == "button1" then
            attr = 0x0200
            payload = data<0xF0 and 1 or 0
        end

        if attr then
            device:send(cluster_base.write_manufacturer_specific_attribute(device, OPPLE_CLUSTER, attr, 0x115F, data_types.Uint8, payload) )
        end
      end
    end
end


local function attr_operation_mode_handler(driver, device, value, zb_rx)
    log.info("attr_operation_mode_handler " .. tostring(value))
    device:set_field("operationMode", value.value, {persist = true})
end

local old_switch_handler = {
    NAME = "Zigbee3 Aqara/Opple",
    capability_handlers = {
        [capabilities.refresh.ID] = {
          [capabilities.refresh.commands.refresh.NAME] = do_refresh,
        }
    },
    zigbee_handlers = {
        -- cluster = {
        --   [OnOff.ID] = {
        --       [OnOff.server.commands.OnWithTimedOff.ID] = on_with_timed_off_command_handler
        --   }
        -- },
        attr = {
            [OPPLE_CLUSTER] = {
                [0x0009] = attr_operation_mode_handler,
                [0x00F7] = xiaomi_utils.handler
            },
            -- [OnOff.ID] = {
                --- [0x00F5] = UInt32 0x070000[req_reqNo], 0x03AB5E00 -- probably a debug info, displays who requested on/off
            --}, 
        }
    },
    lifecycle_handlers = {
        infoChanged = info_changed,
        doConfigure = do_configure,
    },
    zdo = {
        [mgmt_bind_resp.MGMT_BIND_RESPONSE] = zdo_binding_table_handler
    },
    can_handle = is_opple
}

return old_switch_handler
