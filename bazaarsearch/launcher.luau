--!strict

-- ============================= --
-- ====== TYPES DEFINITION ===== --
-- ============================= --

-- Type definition for bzrCreateErrorReport param type
type BzrErrReport = {
  cmd_string: string?,  -- The command run before this error
  stage: string?,       -- The function this error was called from
  query: string,        -- The query string the user input. Required.
  err_title: string,    -- The title this error should display. Required.
  err_body: string?,    -- The subtitle (body) this error should display.
}

-- Type definition for the return value of bzrInitialSearch()
type BzrInitialSearchReturn = {
  entries_string: string, -- The string generated for the command in bzrGetMetadata()
  num_elem: number,       -- The number of elements inside of `entries_string`
}

-- Type definition for any bzrNotifyError functions
type BzrNotifyErrorFunction = (query: string, error: BzrErrReport) -> ()

-- Type definition for callback tables passed into bzr methods
type BzrCallbackTable = {
  -- Function call made when going to "bzrGetMetadata()" step
  get_meta_func: ((query: string, initial_bazaar_search: BzrInitialSearchReturn, callbacks: BzrCallbackTable) -> ())?,
  -- Function call made when going to "bzrInitialSearch()" step
  initial_search_func: ((query: string, callbacks: BzrCallbackTable) -> ())?,
  -- Function call for transitioning between multiple steps
  bzr_notify_func: ((query: string, initial_bazaar_search: BzrInitialSearchReturn, callbacks: BzrCallbackTable) -> ())?,
  -- Error call made when error is found in "bzrInitialSearch()"
  bzr_notify_error_initsearch_func: BzrNotifyErrorFunction?,
  -- Error call made when error is found in "bzrGetMetadata()"
  bzr_notify_error_getmetadata_func: BzrNotifyErrorFunction?,
}


-- Imitating Rust Result<> type via Lua

type BzrOk<T> = { ok: true, data: T }
type BzrErr<E> = { ok: false, err: E }
type BzrResult<T, E> = BzrOk<T> | BzrErr<E>

-- Instantiates a BzrOK table. For use with BzrResult
-- return types.
local function bzrMakeOk<T>(data: T): BzrOk<T>
  return { ok = true, data = data }
end

-- Instantiates a BzrErr table. For use with BzrResult
-- return types
local function bzrMakeErr<E>(err: E): BzrErr<E>
  return { ok = false, err = err }
end

type BzrTestTable = {
  order: { string },
  categories: { [string]: BzrTestCategory },
}
type BzrTestCategory = {
  id: string,
  name: string,
  description: string,
  -- The order to display the tests in
  order: {string},
  tests: { [string]: BzrTestDescriptor },
}
type BzrTestDescriptor = {
  id: string,
  name: string,
  description: string,
  test_fn: () -> BzrTestResult,
  result: BzrTestResult?,
}
type BzrTestResult = BzrResult<nil, string>

-- Helper function to create BzrTestTable
local function bzrCreateTestTable(categories: {BzrTestCategory}): BzrTestTable
  local order: {string} = {}
  local cats: {[string]: BzrTestCategory} = {}

  for i=1,#categories do
    table.insert(order, categories[i].id)
    cats[categories[i].id] = categories[i]
  end
  return {
    order = order,
    categories = cats,
  }
end

-- Helper function to create BzrTestCategory
local function bzrCreateTestCategory
(
  data: { id: string, name: string, description: string },
  tests: {BzrTestDescriptor}
): BzrTestCategory
  
  local order: {string} = {}
  local test_descs: {[string]: BzrTestDescriptor} = {}

  for i=1,#tests do
    table.insert(order, tests[i].id)
    test_descs[tests[i].id] = tests[i]
  end
  return {
    name = data.name,
    id = data.id,
    description = data.description,
    order = order,
    tests = test_descs,
  }
end



-- ======================== --
-- ===== GLOBAL STATE ===== --
-- ======================== --

-- The most recent query that should be searched for.
-- Updated in onQuery()
local BZR_CURRENT_QUERY: string | nil = nil


-- ================================= --
-- ===== APPLICATION FUNCTIONS ===== --
-- ================================= --

-- General Application flow:
--
-- <User Input>
-- ├── Check for `busctl`. If it does not exist, bzrNotifyError(). Execution stops
-- │ initialBazaarSearch()
-- ├── On error: bzrNotifyError(). Execution Stops
-- │ bzrNotify( callback = getMetadata )
-- ├── If global query does not match passed in query, stop execution.
-- │ getMetadata()
-- ├── If global query does not match passed in query, stop execution.
-- ├── On other error: bzrNotifyError(). Execution stops
-- │ bzrNotify( callback = bzrFinishQuery )
-- ├── If global query does not match passed in query, stop execution.
-- │ Set results. Stop Execution



-- Input sanitization function for Flatpak IDs
-- As per Flatpak (https://docs.flatpak.org/en/latest/conventions.html)
-- and the DBus naming convention (https://dbus.freedesktop.org/doc/dbus-specification.html#message-protocol-names),
-- the only allowed characters in Flatpak IDs are "[a-z][A-Z][0-9]_-."
--
-- Returns the sanitized string
local function bzrFlatpakIDSanitize(s: string): string
  local retval, _ = s:gsub("[^a-zA-Z0-9_%-%.]", "")
  return retval
end


-- Input sanitization function for user input (shell scripts)
-- As per the Open Group Base Spec (https://pubs.opengroup.org/onlinepubs/9799919799/)
-- definition of POSIX double quoting, the characters that retain special
-- functionality are the quote, backslash, backquote, and dollar sign.
-- This method simply removes all instances of these characters, as they
-- generally shouldn't be needed for general purpose searches.
--
-- Returns the sanitized string
local function bzrUserInputSanitize(s: string): string
  local retval, _ = s:gsub("[%$`\"\\\\]", "")
  return retval
end


-- Helper function to generate an error entry in the case
-- that something goes wrong
--
-- Returns a table row that the launcher will put as an
-- entry.
local function bzrCreateErrorReport(data: BzrErrReport): LauncherResult
  local cmd_string = data["cmd_string"] and tostring(data["cmd_string"]) or "no command provided"
  local stage = data["stage"] and tostring(data["stage"]) or "no stage provided"
  local query = data["query"] and tostring(data["query"]) or "no query provided"
  local err_title = data["err_title"] and tostring(data["err_title"]) or "no error title provided"
  local err_body = data["err_body"] and tostring(data["err_body"]) or ""

  local full_err_msg = "ERROR REPORT\n"
                    .. "Stage: " .. stage .. "\n"
                    .. "Command: " .. cmd_string .. "\n"
                    .. "Query: " .. query .. "\n"
                    .. "Error: " .. err_title .. "\n"
                    .. err_body


  return {
    id = "bzrerror:" .. full_err_msg,
    title = err_title,
    subtitle = "Select this to copy an error report for the maintainer.",
    glpyh = "toast-error"
  }
end


-- This is called after any async process to:
--   1. Check that the query has not changed (and therefore
--      invalidates the busctl output from the previous step)
--   2. Continue onto the next stage of the process (executing
--      the provided callback function)
-- bzrNotify (and the future bzrNotifyTestError) are here as
-- help for the builtin test command `/bzr .dbg`, since we
-- use these methods to inspect data in between steps.
local function bzrNotify(query: string, callback: () -> ())
  -- Stop execution of process if the query is not the same
  -- as the global current query, since we are offset from
  -- what the user wants.
  if query ~= BZR_CURRENT_QUERY then
    return
  end

  -- Continue onto the next part of the process
  callback()
end


-- Similarly to bzrNotify(), this is called during an
-- async process, however this is done when an error occurs.
-- Will either stop execution entirely if the query has changed,
-- or will display the provided error row and change the global
-- query to `nil` (aka. handled)
local function bzrNotifyError(query: string, error: BzrErrReport)
  -- Stop execution if query has changed
  if query ~= BZR_CURRENT_QUERY then
    return
  end

  -- We are handling this query, so change the global state to nil
  BZR_CURRENT_QUERY = nil

  launcher.setResults(query, { bzrCreateErrorReport(error) })
end


-- Called after success of bzrGetMetadata and passing bzrNotify.
-- Simply ensures that the query has not changed, then posts the
-- results into the launcher.
local function bzrFinishQuery(query: string, rows: {LauncherResult})
  -- Stop execution if query has changed
  if query ~= BZR_CURRENT_QUERY then
    return
  end

  BZR_CURRENT_QUERY = nil
  launcher.setResults(query, rows)
end

-- Takes in the item IDs from the iniial bazaar search, then
-- gets metadata and adds them into rows
--
-- Returns rows generated, or an optional error row in the
-- case of problems arising.
local function bzrGetMetadata(query: string, bzr_search_data: BzrInitialSearchReturn, bzr_err_func: BzrNotifyErrorFunction)
  
  -- Construct our second command, this time getting metadata
  -- from the GetResultMetas DBus function
  
  local cmd_string = "busctl --user --json=short "
                  .. "call io.github.kolunmi.Bazaar "
                  .. "/io/github/kolunmi/Bazaar/SearchProvider "
                  .. "org.gnome.Shell.SearchProvider2 "
                  .. "GetResultMetas "
                  .. bzr_search_data.entries_string

  noctalia.runAsync(cmd_string,
    function(result)

      if result.exitCode ~= 0 then
        -- busctl failed, print stderr so we can see why
        return bzr_err_func(query, {
          cmd_string = cmd_string,
          stage = "getMetadata",
          query = query,
          err_title = "'busctl' failed with exit code " .. tostring(result.exitCode),
          err_body = result.stderr
        })
      end

      -- Get Tabular version of data thanks to JSON parsing
      local busdata, err = noctalia.json.decode(result.stdout)
      if not busdata then
        return bzr_err_func(query, {
          cmd_string = cmd_string,
          stage = "getMetadata",
          err_title = "Failed to parse 'busctl' JSON data",
          err_body = err,
          query = query,
        })
      end

      -- Double check the parameter type
      if busdata["type"] ~= "aa{sv}" then
        return bzr_err_func(query, {
          cmd_string = cmd_string,
          stage = "getMetadata",
          query = query,
          err_title = "Search returned malformed value - 'busctl' return type identifier is incorrect",
          err_body = "Expected \"aa{sv}\", got \"" .. busdata["type"] .. "\"",
        })
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
        local sanitized_fpkid = bzrFlatpakIDSanitize(entry_data[i]["id"]["data"])
        if sanitized_fpkid == entry_data[i]["id"]["data"] then
          table.insert(rows, {
            id = sanitized_fpkid,
            title = entry_data[i]["name"]["data"],
            icon = entry_data[i]["gicon"] and entry_data[i]["gicon"]["data"] or "check",
            subtitle = entry_data[i]["description"] and entry_data[i]["description"]["data"] or "",
          })
        end
      end

      return bzrNotify(query, function() bzrFinishQuery(query, rows) end)
    end
  )
end


-- Takes in the search parameter, passes it to the DBus
-- search interface, and gets a list of things that match
--
-- Returns the data necessary for getMetadata and optionally
-- an error, if something went wrong.
local function bzrInitialSearch(query: string, bzr_err_func: BzrNotifyErrorFunction)
  local text: string = noctalia.string.trim(query)
  local cmd_string = "busctl "
                  .. "--user --json=short "
                  .. "call "
                  .. "io.github.kolunmi.Bazaar "
                  .. "/io/github/kolunmi/Bazaar/SearchProvider "
                  .. "org.gnome.Shell.SearchProvider2 "
                  .. "GetInitialResultSet "
                  .. "as 1 \"" .. bzrUserInputSanitize(text) .. "\""

  noctalia.runAsync(
    cmd_string,
    function(result)
      if result.exitCode ~= 0 then
        -- busctl failed, print stderr so we can see why
        return bzr_err_func(query, {
          cmd_string = cmd_string,
          stage = "initialBazaarSearch",
          query = query,
          err_title = "'busctl' failed with exit code " .. tostring(result.exitCode),
          err_body = result.stderr
        })
      end

      -- Get Tabular version of data thanks to JSON parsing
      local busdata, err = noctalia.json.decode(result.stdout)
      if not busdata then
        return bzr_err_func(query, {
          cmd_string = cmd_string,
          stage = "initialBazaarSearch",
          err_title = "Failed to parse 'busctl' JSON data",
          err_body = err,
          query = query,
        })
      end

      -- Double check the parameter type
      if busdata["type"] ~= "as" then
        return bzr_err_func(query, {
          cmd_string = cmd_string,
          stage = "initialBazaarSearch",
          err_title = "Search returned malformed value - arraystring identifier is incorrect",
          err_body = "Expected \"as\", got \"" .. busdata["type"] .. "\"",
          query = query,
        })
      end

      local obtained_entries = busdata["data"][1]
      -- ### HERE IS WHERE WE MINIMIZE THE NUMBER OF ENTRIES WE PARSE ### --
      local n_elem_to_count = math.min(noctalia.getConfig("max_entries"), #obtained_entries)
      local actual_elem_added = 0
      local entries_string = ""
      for i = 1, n_elem_to_count do
        -- Sanitize Flatpak ID (just in case of malicious input)
        local sanitized_fpkid = bzrFlatpakIDSanitize(obtained_entries[i])
        -- If sanitized ID does not match given ID, skip this. We don't want
        -- any shenanigans happening.
        if sanitized_fpkid == obtained_entries[i] then
          entries_string = entries_string .. " \"" .. sanitized_fpkid .. "\""
          actual_elem_added = actual_elem_added + 1
        end
      end

      -- Craft the cmd input for stage 2
      entries_string = "as " .. tostring(actual_elem_added) .. entries_string

      -- Proceed to step 2 of getting entries
      return bzrNotify(query, function()
        bzrGetMetadata(query, { entries_string = entries_string, num_elem = actual_elem_added }, bzr_err_func)
      end)
    end
  )
end


-- ================================= --
-- ===== TEST MODE DESCRIPTORS ===== --
-- ================================= --

-- === SECTION: bzrFlatpakIDSanitize VALIDATION === --
local BZR_FLATPAK_SANITIZE_TESTS: BzrTestCategory = bzrCreateTestCategory(
  {
    id = "fpk_sanitize",
    name = "Flatpak ID Sanitization",
    description = "Tests relating to the bzrFlatpakIDSanitize() function",
  },
  {
    {
      id = "test_ValidFpkIDStaysSame",
      name = "Valid Flatpak IDs stay the same",
      description = "Tests that valid Flatpak IDs do not get changed after sanitization",
      test_fn = function()
        local correct_fpkid: string = "org.test.Test"
        local correct_fpkid2: string = "com.microsoft.Minecraft.MinecraftPE"
        
        local sanitized_fpkid: string = bzrFlatpakIDSanitize(correct_fpkid)
        local sanitized_fpkid2: string = bzrFlatpakIDSanitize(correct_fpkid2)
        if sanitized_fpkid ~= correct_fpkid then
          return bzrMakeErr("Expected \"" .. correct_fpkid .. "\" to stay the same, got \"" .. sanitized_fpkid .. "\"")
        end

        if sanitized_fpkid2 ~= correct_fpkid2 then
          return bzrMakeErr("Expected \"" .. correct_fpkid2 .. "\" to stay the same, got \"" .. sanitized_fpkid2 .. "\"")
        end

        return bzrMakeOk(nil)
      end,
    },
    {
      id = "test_InvalidFpkIDSanitization",
      name = "Invalid Flatpaks are Sanitized Properly",
      description = "Tests that Flatpak IDs with invalid characters are sanitized correctly",
      test_fn = function()
        local input_fpkid: string = "hell'o.inva$id.n0"
        local correct_sanitized_fpkid: string = "hello.invaid.n0"
        local sanitized_fpkid: string = bzrFlatpakIDSanitize(input_fpkid)

        if sanitized_fpkid ~= correct_sanitized_fpkid then
          return bzrMakeErr(
            "Sanitized \"" .. input_fpkid .. "\", expected \"" ..
            correct_sanitized_fpkid .. "\", but got back \"" .. sanitized_fpkid .. "\""
          )
        end

        return bzrMakeOk(nil)
      end,
    },
  }
)

-- The entire test suite object, complete with descriptions of each test,
-- functions testing each thing, and the result, which can used to display
-- directly in the launcher for in-app debugging.
local BZR_TESTS: BzrTestTable = bzrCreateTestTable({
  BZR_FLATPAK_SANITIZE_TESTS,
})


  -- -- === SECTION: bzrUserInputSanitize VALIDATION === --
  --
  -- -- Tests valid user input stays the same
  -- test_ValidUserInputStaysSame: BzrTestResult?,
  -- -- Tests invalid user input is correctly sanitized
  -- test_InvalidUserInputSanitization: BzrTestResult?,
  -- -- Tests non-local characters are not sanitized out,
  -- -- some flatpaks have these characters in their titles
  -- -- and I don't want to remove them if possible.
  -- test_DifferentLocaleSanitization: BzrTestResult?,
  -- -- Ensure command injection cannot happen via user input
  -- -- sanitization
  -- test_NoUserInputCommandInjection: BzrTestResult?,
  --
  -- -- === SECTION: bzrCreateErrorReport VALIDATION === --
  --
  -- -- Tests that passed in values affect the returned table spec,
  -- -- and values are set correctly
  -- test_CreateErrorReportValuesCorrect: BzrTestResult?,
  -- -- Tests that optional values are, in fact, optional, and return
  -- -- certain specified values
  -- test_OptionalCreateErrorReportValues: BzrTestResult?,
  -- -- Tests that non-optional values are, in fact, not optional, and
  -- -- throw an error when omitted
  -- test_NonOptionalCreateErrorReportValues: BzrTestResult?,
  --
  -- -- === SECTION: bzrGetMetadata VALIDATION === --
  --
  -- -- === SECTION: bzrInitialSearch VALIDATION === --
  --
  -- -- === SECTION: PLUGIN SETTINGS VALIDATION === --
  --
  -- -- Tests whether a low `max_entries` value will actually
  -- -- limit the number of Flatpak responses returned
  -- test_MaxEntriesValueAffectsOutput: BzrTestResult?,
  -- -- Tests whether LESS THAN `max_entries` entries can appear
  -- test_MaxEntriesIsMaximum: BzrTestResult?,
  --
  -- -- === SECTION: RACE CONDITION CHECKS === --
  --
  -- -- Tests whether quickly changing user input will
  -- -- cause invalid queries to run and finish
  -- test_QuickUserInputChangesRaceConds: BzrTestResult?,
  --
  -- -- === SECTION: DEPENDENCIES CHECK === --
  --
  -- -- Tests whether the plugin will stop if `busctl` is not found
  -- -- in the PATH
  -- test_NoBusctlStopsQuery: BzrTestResult?,

-- ==================================== --
-- ===== TEST MODE IMPLEMENTATION ===== --
-- ==================================== --

-- Common Testmode buttons that I don't want to re-write every
-- time they show up
local BZR_COMMON_BUTTONS: {[string]: LauncherResult} = {
  -- Button that returns the user to the categories page
  goto_categories = {
    id = "test:action:gotocategories",
    title = "Show Test Categories",
    glyph = "category-2",
  },

  -- Button that returns the user to the general
  -- Flatpak search page (removes .dbg from query)
  return_pluginsearch = {
    id = "test:action:returnhome",
    title = "Return to Search",
    glyph = "arrow-back",
  },

  -- Returns the user to the root of the testmenu
  return_testmenu = {
    id = "test:action:returntestmenu",
    title = "Return to Test Menu",
    glyph = "arrow-back",
  },
}

-- This function runs a single test and populates the result value.
-- Because a lot of async actions happen during these tests, this
-- function will wait until the test considers itself concluded before
-- continuing. This is so that each test can run on its own, without
-- causing race conditions amongst each other.
local function bzrRunSingleTest(test_desc: BzrTestDescriptor)
  -- return value is success/failure of test
  local test_result = test_desc.test_fn()
  test_desc.result = test_result
end
-- This function runs every test in a given category.

-- This is the actual function that runs every single test.

-- This function takes a query beginning with .dbg and
-- loads the test mode menu based on the format of the
-- query
local function bzrTestModeHandleQuery(query: string)
  
  -- Internal helper function for creating a row description
  -- containing test result statuses
  local function _genTestRow(action: string, category_id: string, test_description: BzrTestDescriptor): LauncherResult
  
    return {
      id = "test:" .. action .. ":" .. category_id .. "/" .. test_description.id,
      title = (test_description.result == nil and "[NOT RUN] " or
              test_description.result and test_description.result.ok and "[SUCCESS] " or
              test_description.result and not test_description.result.ok and "[FAIL] "
              or ""),
      glyph = test_description.result == nil and "dots-circle-horizontal" or
              test_description.result and test_description.result.ok and "circle-check" or
              test_description.result and not test_description.result.ok and "exclamation-circle" or
              "adjustments-question",
    }
  end

  -- Check for a query substring - show different menus based on
  -- what we find.
  local query_substr: string? = query:match("^%.dbg%s+(.*)$")
  if query_substr then

    -- If query substring is "category:<category_id> test:<test_id>",
    -- go to the test's page.
    local findtest_category_id: string?, findtest_test_id: string? = query_substr:match("^category:([%w_]+)%s+test:([%w_]+)")
    if findtest_category_id and findtest_test_id then
      local both_exist = BZR_TESTS.categories[findtest_category_id] and
                          BZR_TESTS.categories[findtest_category_id].tests[findtest_test_id]
      if not both_exist then
        launcher.setResults(query, {{
          id = BZR_COMMON_BUTTONS.return_testmenu.id,
          title = BZR_COMMON_BUTTONS.return_testmenu.title,
          subtitle = "Selected test does not exist.",
          glyph = BZR_COMMON_BUTTONS.return_testmenu.glyph,
        }})
        return
      end

      -- We know that the test exists now, so show details about it.
      local test_description: BzrTestDescriptor = BZR_TESTS
        .categories[findtest_category_id]
        .tests[findtest_test_id]

      local generated_run_button: LauncherResult = _genTestRow("runtest", findtest_category_id, test_description)
      generated_run_button.subtitle = "Select this to run the test"

      local error_msg = test_description.result and test_description.result.ok == false and test_description.result.err or ""

      local buttons: {LauncherResult} = {
        {
          id = "",
          title = test_description.name,
          subtitle = "ID: " .. test_description.id,
          glyph = "notes",
        },
        generated_run_button,
        {
          id = "bzrerror:" .. error_msg,
          title = "Error message (if it exists)",
          subtitle = error_msg,
          glyph = "clipboard-x",
        },
        BZR_COMMON_BUTTONS.goto_categories,
        BZR_COMMON_BUTTONS.return_testmenu,
      }

      launcher.setResults(query, buttons)
      return
    end
    
    -- If query substring is "categories", show list of categories
    if query_substr == "categories" then
      -- loop through categories and display a row based
      -- on its information
      local tbl_results: {LauncherResult} = {}
      for i=1,#BZR_TESTS.order do
        local category_id: string = BZR_TESTS.order[i]
        local launcher_res: LauncherResult = {
          id = "test:viewcategory:" .. category_id,
          title = BZR_TESTS.categories[category_id].name,
          subtitle = BZR_TESTS.categories[category_id].description,
          glyph = "arrow-badge-right",
        }
        table.insert(tbl_results, launcher_res)
      end

      -- insert "return to test menu" option
      table.insert(tbl_results, BZR_COMMON_BUTTONS.return_testmenu)
      launcher.setResults(query, tbl_results)
      return
    end


    -- If query has category:<categoryname> directly after
    -- `.dbg`, then show category page, if it exists
    local category_match: string? = query_substr:match("^category:([%w_]+)")
    if category_match and BZR_TESTS.categories[category_match] then
      local category_ref: BzrTestCategory = BZR_TESTS.categories[category_match]
      local tbl_results: {LauncherResult} = {}
      for j=1,#category_ref.order do
        local test_id = category_ref.order[j]
        local test_desc: BzrTestDescriptor = category_ref.tests[test_id]
        local result: LauncherResult = _genTestRow("view", category_match, test_desc)

        -- This cast is done because we can guarantee that "title" will
        -- be fulfilled from the function call
        result.title = result.title::string .. test_desc.name
        table.insert(tbl_results, result)
      end

      -- Add "Go Back To Test Menu" Button
      table.insert(tbl_results, BZR_COMMON_BUTTONS.return_testmenu)
      
      -- we've aggregated our things, now display them
      launcher.setResults(query, tbl_results)
    end

    return
  end

  -- Else, show main test menu
  launcher.setResults(query, {
    BZR_COMMON_BUTTONS.goto_categories,
    BZR_COMMON_BUTTONS.return_pluginsearch,
  })
end


-- ================================================ --
-- ===== NOCTALIA LAUNCHER OVERRIDE FUNCTIONS ===== --
-- ================================================ --

-- onQuery is what we call when the search text changes
function onQuery(query: string)

  BZR_CURRENT_QUERY = query
  local trimmed_query = noctalia.string.trim(query)


  if not noctalia.commandExists("busctl") then
    -- No busctl command, display error
    BZR_CURRENT_QUERY = nil
    bzrNotifyError(query, {
      cmd_string = "noctalia.commandExists(\"busctl\")",
      query = query,
      stage = "onQuery",
      err_title = "'busctl' is not found in the PATH",
      err_body = "Please make sure that 'busctl' is installed and is correctly set somewhere along the PATH",
    })
    return
  end

  -- Test mode enabled, as well as typing in test phrase
  if noctalia.getConfig("testmode_enable") then
    local forced_reload_path = query:match("^.dbg forcereload (.*)$")
    if forced_reload_path then
      BZR_CURRENT_QUERY = nil
      launcher.setResults(query, {{}})
      launcher.setQuery(forced_reload_path)
      return
    end
    if trimmed_query:sub(1, 4) == ".dbg" then
      BZR_CURRENT_QUERY = nil
      bzrTestModeHandleQuery(query)
      return
    end
  end

  -- Otherwise, do Bazaar search
  bzrInitialSearch(query, bzrNotifyError)
end

--onActivate is what is called when we press Enter on something
function onActivate(id: string)
  local errmsg = id:match("^bzrerror:(.+)$")
  if errmsg then
    noctalia.copyToClipboard(errmsg, "text/plain")
    noctalia.notify("Bazaar Search Error", "Error message copied to clipboard.")
    return
  end

  -- Handle test-mode commands
  local test_cmd = id:match("^test:(.+)$")
  if test_cmd then
    local subcmd: string?, tertcmd: string? = test_cmd:match("^(.+):(.+)$")
    if not subcmd or not tertcmd then
      noctalia.notifyError("Bazaar Testmode Error", "Given test command \"" .. id .. "\" is invalid.")
      return 
    end

    local cmd_table: { [string]: { [string]: () -> ()} | (param: string) -> () } = {
      action = {
        gotocategories = function()
          -- Go to categories page
          launcher.setQuery(".dbg categories")
        end,
        returnhome = function()
          -- Return to search bar without closing launcher
          launcher.setQuery(" ")
        end,
        returntestmenu = function()
          launcher.setQuery(".dbg")
        end,
      },
      runtest = function(param: string)
        -- param is a string in the format "<category_id>/<test_id>",
        -- so run test, then re-evaluate page
        local category_id: string?, test_id: string? = param:match("^(.*)/(.*)$")
        if not category_id or not test_id then
          noctalia.notifyError(
            "Bazaar Testmode Error: Bad Category/Test ID for `runtest`",
            "Category: " .. tostring(category_id) .. ", Test: " .. tostring(test_id)
          )
          return
        end
        if BZR_TESTS.categories[category_id] and BZR_TESTS.categories[category_id].tests[test_id] then
          -- Run that test
          bzrRunSingleTest(BZR_TESTS.categories[category_id].tests[test_id])
          
          -- Go back to the individual test's page
          launcher.setQuery(".dbg forcereload .dbg category:" .. category_id .. " test:" .. test_id)
          return
        else
          noctalia.notifyError(
            "Bazaar Testmode Error: No such test for `runtest`",
            "Category: " .. tostring(category_id) .. ", Test: " .. tostring(test_id)
          )
          return
        end
      end,
      view = function(param: string)
        -- param is a string in the format "<category_id>/<test_id>",
        -- so navigate to the specified test's page
        local category_id: string?, test_id: string? = param:match("^(.*)/(.*)$")
        if not category_id or not test_id then
          noctalia.notifyError(
            "Bazaar Testmode Error: Bad Category/Test ID",
            "Category: " .. tostring(category_id) .. ", Test: " .. tostring(test_id)
          )
          return
        end
        launcher.setQuery(".dbg category:" .. category_id .. " test:" .. test_id)
      end,
      viewcategory = function(param: string)
        -- param in this case will be the id of a category,
        -- so simply update the query with category:<id>
        launcher.setQuery(".dbg category:" .. param)
      end,
    }
    
    -- Check if command in table leads to another table, or directly to
    -- a function with `tertcmd` as an argument
    if cmd_table[subcmd] and type(cmd_table[subcmd]) == "table" then
      local subcmd_tbl: { [string]: () -> () } = cmd_table[subcmd] :: { [string]: () -> () }
      if subcmd_tbl[tertcmd] then
        subcmd_tbl[tertcmd]()
        return
      end
    elseif cmd_table[subcmd] and type(cmd_table[subcmd]) == "function" then
      local subcmd_fun: (param: string) -> () = cmd_table[subcmd] :: (param: string) -> ()
      subcmd_fun(tertcmd)
      return
    else
      noctalia.notifyError("Bazaar Testmode Error", "Given test command \"" .. id .. "\" does not exist.")
      return
    end
  end

  if id ~= "" then
    local sanitized_fltpk = bzrFlatpakIDSanitize(id)
    if sanitized_fltpk == id then
      noctalia.runAsync(
        "busctl --user "
        .. " call io.github.kolunmi.Bazaar "
        .. "/io/github/kolunmi/Bazaar/SearchProvider "
        .. "org.gnome.Shell.SearchProvider2 "
        .. "ActivateResult "
        .. "sasu \"" .. id .. "\" 0 " .. tostring(os.time()) 
      )
    else
      noctalia.notifyError("Bazaar Search Error", "Selected Flatpak ID failed sanitization check, ignoring launch command.")
    end
  end
end
