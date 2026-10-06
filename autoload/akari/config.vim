vim9script

export def Options(): dict<any>
	var configured: any = get(g:, 'akari_options', {})
	if type(configured) != v:t_dict
		throw 'akari: g:akari_options must be a dictionary'
	endif
	var options: dict<any> = {
		default_model: '',
		system_prompt: '',
		instructions_file: '',
		stream: false,
		always_allow_tools: [],
		log_file: '',
	}
	extend(options, deepcopy(configured), 'force')
	for key in ['default_model', 'system_prompt', 'log_file']
		if type(options[key]) != v:t_string
			throw 'akari: option ' .. key .. ' must be a string'
		endif
	endfor
	if type(options.stream) != v:t_bool
		throw 'akari: option stream must be a boolean'
	endif
	var instructions: any = options.instructions_file
	if type(instructions) == v:t_list
		for path in instructions
			if type(path) != v:t_string
				throw 'akari: option instructions_file must be a string or a list of strings'
			endif
		endfor
	elseif type(instructions) != v:t_string
		throw 'akari: option instructions_file must be a string or a list of strings'
	endif
	if type(options.always_allow_tools) != v:t_list
		throw 'akari: option always_allow_tools must be a list of strings'
	endif
	for name in options.always_allow_tools
		if type(name) != v:t_string
			throw 'akari: option always_allow_tools must be a list of strings'
		endif
	endfor
	return options
enddef

def Models(): dict<any>
	var models: any = get(g:, 'akari_models', {})
	if type(models) != v:t_dict
		throw 'akari: g:akari_models must be a dictionary'
	endif
	return models
enddef

export def ModelNames(): list<string>
	return sort(keys(Models()))
enddef

export def Model(name: string): dict<any>
	var models = Models()
	if !has_key(models, name)
		throw 'akari: unknown model: ' .. string(name)
	endif
	if type(models[name]) != v:t_dict
		throw 'akari: model configuration must be a dictionary: ' .. name
	endif
	var model: dict<any> = {
		type: 'chat_completions',
		timeout: 60000,
		api_key: '',
	}
	extend(model, deepcopy(models[name]), 'force')
	for key in ['endpoint', 'model']
		if type(get(model, key, v:null)) != v:t_string || model[key] == ''
			throw 'akari: model ' .. name .. ': ' .. key .. ' must be a non-empty string'
		endif
	endfor
	if type(model.type) != v:t_string || index(['chat_completions', 'responses'], model.type) < 0
		throw 'akari: model ' .. name .. ': type must be chat_completions or responses'
	endif
	if type(model.timeout) != v:t_number || model.timeout <= 0
		throw 'akari: model ' .. name .. ': timeout must be a positive number'
	endif
	for key in [model.type == 'responses' ? 'input' : 'messages', 'stream', 'tools']
		if has_key(model, key)
			throw 'akari: model ' .. name .. ': cannot define generated field: ' .. key
		endif
	endfor
	if type(model.api_key) != v:t_string
		throw 'akari: model ' .. name .. ': api_key must be a string'
	endif
	if model.api_key != '' && model.api_key[0] == '$'
		var variable = strpart(model.api_key, 1)
		if variable == '' || !exists('$' .. variable)
			throw 'akari: model ' .. name .. ': environment variable is not set: ' .. variable
		endif
		var value: any = getenv(variable)
		# Vim can return null for an existing environment variable with an empty value.
		model.api_key = type(value) == v:t_none ? '' : value
	endif
	return model
enddef
