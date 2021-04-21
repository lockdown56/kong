local perf = require("spec.helpers.perf")

perf.set_log_level(ngx.INFO)
--perf.set_retry_count(3)

local driver = os.getenv("PERF_TEST_DRIVER") or "docker"

if driver == "terraform" then
  perf.use_driver("terraform", {
    provider = "equinix-metal",
    tfvars = {
      -- Kong Benchmarking
      packet_project_id = os.getenv("PERF_TEST_PACKET_PROJECT_ID"),
      -- TODO: use an org token
      packet_auth_token = os.getenv("PERF_TEST_PACKET_AUTH_TOKEN"),
      -- packet_plan = "baremetal_1",
      -- packet_region = "sjc1",
      -- packet_os = "ubuntu_20_04",
    }
  })
else
  perf.use_driver(driver)
end

local versions = { "2.3.1", "2.3.3", "2.4.0" }

local SERVICE_COUNT = 10
local ROUTE_PER_SERVICE = 10
local CONSUMER_COUNT = 100

local wrk_script = [[
  --This script is originally from https://github.com/Kong/miniperf
  math.randomseed(os.time()) -- Generate PRNG seed
  local rand = math.random -- Cache random method
  -- Get env vars for consumer and api count or assign defaults
  local consumer_count = ]] .. CONSUMER_COUNT .. [[
  local service_count = ]] .. SERVICE_COUNT .. [[
  local route_per_service = ]] .. ROUTE_PER_SERVICE .. [[
  function request()
    -- generate random URLs, some of which may yield non-200 response codes
    local random_consumer = rand(consumer_count)
    local random_service = rand(service_count)
    local random_route = rand(route_per_service)
    -- Concat the url parts
    url_path = string.format("/s%s-r%s?apikey=consumer-%s", random_service, random_route, random_consumer)
    -- Return the request object with the current URL path
    return wrk.format(nil, url_path, headers)
  end
]]

for _, version in ipairs(versions) do
  describe("perf test for Kong " .. version .. " #baseline #no_plugins", function()
    local bp, db
    lazy_setup(function()
      local helpers = perf.setup()

      bp, db = helpers.get_db_utils(strategy, {
        "routes",
        "services",
      })

      local upstream_uri = perf.start_upstream([[
      location = /test {
        return 200;
      }
      ]])

      for i=1, SERVICE_COUNT do
        local service = bp.services:insert {
          url = upstream_uri .. "/test",
        }

        for j=1, ROUTE_PER_SERVICE do
          bp.routes:insert {
            paths = { string.format("/s%d-r%d", i, j) },
            service = service,
            strip_path = true,
          }
        end
      end
    end)

    before_each(function()
      perf.start_kong(version, {
        --kong configs
      })
    end)

    after_each(function()
      perf.stop_kong()
    end)

    lazy_teardown(function()
      perf.teardown(os.getenv("PERF_TEST_TERADOWN_ALL") or false)
    end)

    it("#single_route", function()
      local results = {}
      for i=1,3 do
        perf.start_load({
          path = "/s1-r1",
          connections = 1000,
          threads = 5,
          duration = 10,
        })

        ngx.sleep(10)

        local result = assert(perf.wait_result())

        print(("### Result for Kong %s (run %d):\n%s"):format(version, i, result))
        results[i] = result
      end

      print("### Combined results:\n" .. assert(perf.combine_results(results)))
    end)

    it(SERVICE_COUNT .. " services each has " .. ROUTE_PER_SERVICE .. " routes", function()
      local results = {}
      for i=1,3 do
        perf.start_load({
          connections = 1000,
          threads = 5,
          duration = 10,
          script = wrk_script,
        })

        ngx.sleep(10)

        local result = assert(perf.wait_result())

        print(("### Result for Kong %s (run %d):\n%s"):format(version, i, result))
        results[i] = result
      end

      print("### Combined results:\n" .. assert(perf.combine_results(results)))
    end)
  end)

  describe("perf test for Kong " .. version .. " #baseline #key-auth", function()
    local bp, db
    lazy_setup(function()
      local helpers = perf.setup()

      bp, db = helpers.get_db_utils(strategy, {
        "routes",
        "services",
        "plugins",
        "consumers",
        "keyauth_credentials",
      })

      local upstream_uri = perf.start_upstream([[
        location = /test {
          return 200;
        }
        ]])

        for i=1, CONSUMER_COUNT do
          local name = "consumer-" .. i
          local consumer = bp.consumers:insert {
            username = name,
          }

          bp.keyauth_credentials:insert {
            key      = name,
            consumer = consumer,
          }
        end

        for i=1, SERVICE_COUNT do
          local service = bp.services:insert {
            url = upstream_uri .. "/test",
          }

          bp.plugins:insert {
            name = "key-auth",
            service = service,
          }

          for j=1, ROUTE_PER_SERVICE do
            bp.routes:insert {
              paths = { string.format("/s%d-r%d", i, j) },
              service = service,
              strip_path = true,
            }
          end
        end
    end)

    before_each(function()
      perf.start_kong(version, {
        --kong configs
      })
    end)

    after_each(function()
      perf.stop_kong()
    end)

    lazy_teardown(function()
      perf.teardown(os.getenv("PERF_TEST_TERADOWN_ALL") or false)
    end)

    it(SERVICE_COUNT .. " services each has  " .. ROUTE_PER_SERVICE .. " routes " ..
      "with key-auth, " .. CONSUMER_COUNT .. " consumers", function()
      local results = {}
      for i=1,3 do
        perf.start_load({
          connections = 1000,
          threads = 5,
          duration = 10,
          script = wrk_script,
        })

        ngx.sleep(10)

        local result = assert(perf.wait_result())

        print(("### Result for Kong %s (run %d):\n%s"):format(version, i, result))
        results[i] = result
      end

      print("### Combined results:\n" .. assert(perf.combine_results(results)))
    end)
  end)
end