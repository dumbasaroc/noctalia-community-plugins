-- Takes in the item IDs from the iniial bazaar search, then
-- gets metadata and adds them into rows
-- @param query The query string (needed for setting the results)
local function getMetadata(query, entriesString, expectedNumElements)
  
  -- Construct our second command, this time getting metadata
  -- from the GetResultMetas DBus function
  local cmd_ok = noctalia.runAsync(
    "busctl --user --json=short "
    .. "call io.github.kolunmi.Bazaar "
    .. "/io/github/kolunmi/Bazaar/SearchProvider "
    .. "org.gnome.Shell.SearchProvider2 "
    .. "GetResultMetas "
    .. entriesString,
    function(result)

      if result.exitCode ~= 0 then
        -- busctl failed, print stderr so we can see why
        launcher.setResults(query, {{
          id = "nilnil",
          title = "'busctl' failed with exit code " .. tostring(result.exitCode),
          subtitle = result.stderr,
          glpyh = "toast-error",
        }})
        return
      end

      -- Get Tabular version of data thanks to JSON parsing
      local busdata, err = noctalia.json.decode(result.stdout)
      if not busdata then
        launcher.setResults(query, {{
          id = "nilnil",
          title = "Failed to parse 'busctl' JSON data",
          subtitle = err,
          glpyh = "toast-error",
        }})
        return
      end

      -- Double check the parameter type
      if busdata["type"] ~= "aa{sv}" then
        launcher.setResults(query, {{
          id = "nilnil",
          title = "Search returned malformed value - arraystring identifier is incorrect",
          subtitle = "Expected \"aa{sv}\", got \"" .. busdata["type"] .. "\"",
          glpyh = "toast-error",
        }})
        return
      end

      
      -- Iterate through table, creating row descriptions based
      -- on the given metadata
      
      local rows = {}
      -- The [1] at the end is because we only care about
      -- one single query, which is the one we're making.
      -- This interface technically lets us search a whole
      -- bunch of things if we want to
      local entry_data = busdata["data"][1]
      for i = 1, #entry_data do
        table.insert(rows, {
          id = entry_data[i]["id"]["data"],
          title = entry_data[i]["name"]["data"],
          icon = entry_data[i]["gicon"] and entry_data[i]["gicon"]["data"] or "check",
          subtitle = entry_data[i]["description"] and entry_data[i]["description"]["data"] or "",
        })
      end

      launcher.setResults(query, rows)

      -- launcher.setResults(query, {{
      --   id = "nilnil",
      --   title = "Correct so far",
      --   glyph = "check",
      -- }})
    end
  )
end


-- Takes in the search parameter, passes it to the DBus
-- search interface, and gets a list of things that match
local function initialBazaarSearch(query)
  local text = noctalia.string.trim(query)
  local cmd_ok = noctalia.runAsync(
    "busctl "
    .. "--user --json=short "
    .. "call "
    .. "io.github.kolunmi.Bazaar "
    .. "/io/github/kolunmi/Bazaar/SearchProvider "
    .. "org.gnome.Shell.SearchProvider2 "
    .. "GetInitialResultSet "
    .. "as 1 '" .. text:gsub("'", "\\'") .. "'",

    function(result)
      if result.exitCode ~= 0 then
        -- busctl failed, print stderr so we can see why
        launcher.setResults(query, {{
          id = "nilnil",
          title = "'busctl' failed with exit code " .. tostring(result.exitCode),
          subtitle = result.stderr,
          glpyh = "toast-error",
        }})
        return
      end

      -- Get Tabular version of data thanks to JSON parsing
      local busdata, err = noctalia.json.decode(result.stdout)
      if not busdata then
        launcher.setResults(query, {{
          id = "nilnil",
          title = "Failed to parse 'busctl' JSON data",
          subtitle = err,
          glpyh = "toast-error",
        }})
        return
      end

      -- Double check the parameter type
      if busdata["type"] ~= "as" then
        launcher.setResults(query, {{
          id = "nilnil",
          title = "Search returned malformed value - arraystring identifier is incorrect",
          subtitle = "Expected \"as\", got \"" .. busdata["type"] .. "\"",
          glpyh = "toast-error",
        }})
        return
      end

      local obtained_entries = busdata["data"][1]
      -- ### HERE IS WHERE WE MINIMIZE THE NUMBER OF ENTRIES WE PARSE ### --
      local n_elem_to_count = math.min(noctalia.getConfig("max_entries"), #obtained_entries)
      local entries_string = "as " .. tostring(n_elem_to_count)
      for i = 1, n_elem_to_count do
        -- simply append the name of the ID in quotes to the entries string
        entries_string = entries_string .. " \"" .. obtained_entries[i] .. "\""
      end

      -- Proceed to step 2 of getting entries
      getMetadata(query, entries_string, n_elem_to_count)
    end
  )
end

-- onQuery is what we call when the search text changes
function onQuery(query)
  if not noctalia.commandExists("busctl") then
    -- No busctl command, display error
    launcher.setResults(query, {{
      id = "nilnil",
      title = "'busctl' is not found",
      subtitle = "Please install the 'busctl' command, this plugin requires it to work!",
      glyph = "toast-error",
    }})
    return
  end
  initialBazaarSearch(query)
end

--onActivate is what is called when we press Enter on something
function onActivate(id)
  if id ~= "" then
    noctalia.runAsync(
     "busctl --user "
     .. " call io.github.kolunmi.Bazaar "
     .. "/io/github/kolunmi/Bazaar/SearchProvider "
     .. "org.gnome.Shell.SearchProvider2 "
     .. "ActivateResult "
     .. "sasu \"" .. id .. "\" 0 " .. tostring(os.time()) 
    )
  end
end
