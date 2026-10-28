local service = require "service"
local root = require "service.root"
local accounts = require "ctp.accounts"
local inspect = require "inspect"

function root.boot(...)
    -- assert(select("#", ...) == 1, "expected exactly one argument: profile name")
    local profile_name  = select(1, ...) or ""
    local server = accounts["trader"][profile_name]

    if not server then 
        service.log.error("no matching server found for profile: " .. profile_name)
    else 
        service.call(0, "run", server)
    end

    service.quit()
end

function root.run(server)
    service.spawn { 
        name = "trader", 
        source = [[return require "ctp.templates.trader"]], 
        config = { server = server } 
    }

    service.call("trader", "start") -- blocking, until trader starts
    
    local position = service.call("trader", "query_position")
    print(inspect(position))

    service.call("trader", "quit")
end 

return root
