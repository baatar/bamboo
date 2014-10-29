module(..., package.seeall)
local lgstring = require "lgstring"
local i18n = require 'bamboo.i18n'
_G.translate = i18n.translate

local function getlocals(context, depth)
  local i = 1
  while true do
    local name, value = debug.getlocal(depth, i)
    if not name then break end
    context[name] = value
    i = i + 1
  end
  return context
end


local function findTemplDir( name )
    -- second, find 'project_dir/views/'
    if posix.access( "views/" + name) then
        return "views/"
    else
        error("Template " + name + " does not exist or wrong permissions.")
    end
end

-- template rendering directives
local VIEW_ACTIONS = {
    -- embeding lua sentances
    ['{%'] = function(code)
        return code
    end,
    -- embeding lua variables
    ['{{'] = function(code)
        return ('_result[#_result+1] = %s'):format(code)
    end,
    -- containing child template
    ['{('] = function(code)
        return ([[
            if not _children[%s] then
                _children[%s] = View(%s)
            end
            _result[#_result+1] = _children[%s](getfenv())
        ]]):format(code, code, code, code)
    end,
--[[
    -- escape tag, to make security
    ['{*'] = function(code)
        return ('local http = require("lglib.http"); _result[#_result+1] = http.escapeHTML(%s)'):format(code)
    end,
--]]
    ['{['] = function(code)
        -- nothing now
        return true
    end,
    -- template inheritation syntax
  -- @param code: the base file's name
  -- @param this_page: the master file rendered
    ['{:'] = function(code, this_page)
        local name = deserialize(code)
        local tmpl_dir = findTemplDir(name)
        local base_page = io.loadFile(tmpl_dir, name)
        local starti = 1
        local oi, oj = 1, 0
        local i, j = 1, 0
        local block, matched, block_content
        local part
        local parts = {}
        while true do
          oi, oj, block = base_page:find("({%[[%s_%w%.%-\'\"]+%]})", oj + 1)
          if oi == nil then break end
            block_content = block:sub(3, -3):trim()
            while true do
              i, j, matched = this_page:find("(%b{})", j + 1)
              
              if i == nil then break end
              part = matched:match('^{%[%s*====*%s*' + block_content +
            '%s*====*%s+(.+)%s*%]}$')
        if part then
          table.insert(parts, base_page:sub(starti, oi-1))
          table.insert(parts, part)
          starti = oj + 1
          break
        end
            end
        end
        table.insert(parts, base_page:sub(starti, -1))

        return table.concat(parts)
    end,

    -- insert plugin
    ['{^'] = function (code)
        local code = code:trim()
        assert( code ~= '', 'Plugin name must not be blank.')
        local divider_loc = code:find('%s')
        local plugin_name = nil
        local param_str = nil

        if divider_loc then
            plugin_name = code:sub(1, divider_loc - 1)
            param_str = '{' .. code:sub(divider_loc + 1) .. '}'
        else
            -- if divider_loc is nil, means this plugin has no arguments
            plugin_name = code
            param_str = "{}"
        end
        assert(bamboo.PLUGIN_LIST[plugin_name], ('[Error] plugin %s was not registered.'):format(plugin_name))
        return ("_result[#_result+1] = bamboo.PLUGIN_LIST['%s'](%s, getfenv())"):format(plugin_name, param_str)

    end,
    
    ['{-'] = function (code)
      return ""
    end,
    
    ['{<'] = function (code)
    local code = code:trim()
        assert( code ~= '', 'Widget name must not be blank.')
        local divider_loc = code:find(' ')
        local widget_name = nil
        local param_str = nil

        if divider_loc then
            widget_name = code:sub(1, divider_loc - 1)
            param_str = '{' .. code:sub(divider_loc + 1) .. '}'
        else
            -- if divider_loc is nil, means this plugin has no arguments
            widget_name = code
            param_str = "{}"
        end
        assert(bamboo.WIDGETS[widget_name], ('[Error] widget %s was not implemented.'):format(widget_name))
        return ("_result[#_result+1] = bamboo.WIDGETS['%s'](%s)"):format(widget_name, param_str)

    end,
    
    ['{_'] = function (code)
      local code = code:trim()
      local ret = ""
      
      --return ('_result[#_result+1] = "%s"'):format(ret)
      return '_result[#_result+1] = translate("'..code..'")'
    end,
    

}

local function inheritate(tmpl)
  -- if there is inherited tag in page, that tag must be put in the front of this file
  local block = tmpl:match("(%b{})")
--	local headtwo = block:sub(1,2)
  local block_content = block:sub(3, -3)
--	assert(headtwo == '{:', 'The inheriate tag must be put in front of the page.')

  local act = VIEW_ACTIONS['{:']
  return act(block_content, tmpl)
end
            
-- NOTE: the instance of this class is a function
local View = Object:extend {
  ------------------------------------------------------------------------
  --
  -- if config.PRODUCTION is true, means it is in production mode, it will only be compiled once every call View()
  -- else, it is in develop mode, it will be compiled every request coming in, in compile stage and parameter fill stage.
  -- @param name:  the name of the template file
  -- @return:  a function, this function can receive a table to finish the rendering procedure
  ------------------------------------------------------------------------
  init = function (self, name, is_inline)
    local tmpl
    if not name then return '' end
    
    -- call this to calc languageEnv to i18n.
    if req then i18n.langcode(req) end
    
    if bamboo.config.PRODUCTION then
      -- if cached
      -- NOTE: here, 5 is an empiric value
      bamboo.compiled_views_locals[name] = getlocals({}, 4)
        
      local view = bamboo.compiled_views[name]
      if view and type(view) == 'function' then
        return view
      end
  
      -- passing tmpl directly
      if is_inline == 'inline' then
        -- here, name is the content of html fragment
        tmpl = name
      else
        -- load file
        local tmpl_dir = findTemplDir(name)
        tmpl = io.loadFile(tmpl_dir, name)
      end
      tmpl = self.preprocess(tmpl)
      view = self.compileView(tmpl, name)
      -- add to cache
      bamboo.compiled_views[name] = view
      return view
    else
      return function (params)
        -- passing tmpl directly
        if is_inline == 'inline' then
          -- here, name is the content of html fragment
          tmpl = name
        else
          local tmpl_dir = findTemplDir(name)
          tmpl = io.loadFile(tmpl_dir, name)
          assert(tmpl, "Template " + tmpl_dir + name + " does not exist.")
        end
        tmpl = self.preprocess(tmpl)
        return self.compileView(tmpl, name)(params)
      end
    end
  end;

  -- preprocess course
  preprocess = function(tmpl)

    -- restrict the {: :} at the head of template file, from the first char
    while tmpl:match('^{:.-:}%s*\n') do
      tmpl = inheritate(tmpl)
    end

    tmpl = tmpl:gsub('%[%[%s*====*%s*([\'\"%w_%-]+)%s*====*%s+(.-)%s*====*%s*%]%]', function (skey, sval)
      local firstchar = skey:sub(1,1)
      if firstchar == "'" or firstchar == '"' then skey = skey:sub(2,-2) end
      bamboo.context[skey] = sval
      
      return ''
    end)
    return tmpl
  end;

  ------------------------------------------------------------------------
  -- compile template string to a middle function
  -- use this function to receive a table to finish rendering to html
  --
  -- this snippet is very concise and powerful!
  -- @param tmpl:  template string read from file
  -- @param name:  template file name
  -- @return: middle rendering function
  ------------------------------------------------------------------------
  compileView = function (tmpl, name)
    local tmpl = ('%s{{""}}'):format(tmpl)
    local code = {'local _result, _children = {}, {}\n'}

    -- render the rest
    local text, block
    for text, block in lgstring.matchtagset(tmpl) do
      local act = VIEW_ACTIONS[block:sub(1,2)]

      if act then
        code[#code+1] = '_result[#_result+1] = [==[' + text + ']==]'
        code[#code+1] = act(block:sub(3,-3))
      elseif #block > 2 then
        code[#code+1] = '_result[#_result+1] = [==[' + text + block + ']==]'
      else
        code[#code+1] = '_result[#_result+1] = [==[' + text + ']==]'
      end
    end

    -- do check before concatate
    -- if code[i] is nil, it won't be countered
    -- we must find all viewing bugs in develop mode
    code[#code+1] = [==[ 
      if not bamboo.config.PRODUCTION then
        local ctype
        for i, v in ipairs(_result) do  
          local ctype = type(v)
          if ctype ~= 'string' or ctype ~= 'number' then
            _result[i] = tostring(v)
          end
        end 
      end 
    ]==]
    code[#code+1] = 'return table.concat(_result)'
    code = table.concat(code, '\n')
    -- print('-----', code)
    -- recode each middle view code to request
    if type(name) == 'string' then
      bamboo.compiled_views_tmpls[name] = code
    end

    -- compile the whole string code
    local func, err = loadstring(code, name)

    if err then
        assert(func, err)
    end

    return function(context)
      assert(type(context) == 'table', "You must always pass in a table for context.")
      -- collect locals
      if context[1] == 'locals' then  
        context[1] = nil
        if bamboo.config.PRODUCTION then
          local locals = bamboo.compiled_views_locals[name]
          if locals then
            for k, v in pairs(locals) do
              if not context[k] then context[k] = v end
            end
          end
        else
          -- NOTE: here, 4 is empiric value
          context = getlocals(context, 3)
        end
      end
      
      -- for global context rendering
      for k, v in pairs(bamboo.context) do
        if not context[k] then
          context[k] = v
        end
      end
      setmetatable(context, {__index=_G})
      setfenv(func, context)
      return func()
    end
  end;
}

return View
