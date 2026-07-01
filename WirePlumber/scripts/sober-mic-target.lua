log = Log.open_topic("sober-mic")

SimpleEventHook {
  name = "custom/sober-mic-target",
  after = { "node/create-item" },
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "node-added" },
      Constraint { "node.name", "=", "Sober", type = "pw-global" },
      Constraint { "media.class", "=", "Stream/Input/Audio", type = "pw-global" },
    },
  },
  execute = function (event)
    local source = event:get_source ()
    local node = event:get_subject ()
    local bound_id = node ["bound-id"]

    local nodes_om = source:call ("get-object-manager", "node")
    local b1_node = nodes_om:lookup {
      Constraint { "node.name", "=", "b1_mic", type = "pw" },
    }

    if not b1_node then
      log:warning ("b1_mic not found, cannot route Sober mic")
      return
    end

    local b1_serial = b1_node.properties ["object.serial"]

    local metadata_om = source:call ("get-object-manager", "metadata")
    local metadata = metadata_om:lookup {
      Constraint { "metadata.name", "=", "default" },
    }

    if metadata and b1_serial then
      log:info ("routing Sober capture " .. tostring (bound_id) ..
          " -> b1_mic (serial " .. tostring (b1_serial) .. ")")
      metadata:set (bound_id, "target.object", "Spa:Id", tostring (b1_serial))
    end
  end,
}:register ()
