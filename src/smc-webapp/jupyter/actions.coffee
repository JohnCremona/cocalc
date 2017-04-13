###
Jupyter client

The goal here is to make a simple proof of concept editor for working with
Jupyter notebooks.  The goals are:
 1. to **look** like the normal jupyter notebook
 2. work like the normal jupyter notebook
 3. work perfectly regarding realtime sync and history browsing

###

immutable  = require('immutable')
underscore = require('underscore')

misc       = require('smc-util/misc')
{required, defaults} = misc

{Actions}  = require('../smc-react')

util       = require('./util')
parsing    = require('./parsing')

keyboard   = require('./keyboard')

commands   = require('./commands')

{cm_options} = require('./cm_options')

jupyter_kernels = undefined

###
The actions -- what you can do with a jupyter notebook, and also the
underlying synchronized state.
###

bounded_integer = (n, min, max, def) ->
    if typeof(n) != 'number'
        n = parseInt(n)
    if isNaN(n)
        return def
    n = Math.round(n)
    if n < min
        return min
    if n > max
        return max
    return n


class exports.JupyterActions extends Actions

    _init: (project_id, path, syncdb, store, client) =>
        store.dbg = (f) => return client.dbg("JupyterStore('#{store.get('path')}').#{f}")

        @util = util # TODO: for debugging only
        @_state      = 'init'   # 'init', 'load', 'ready', 'closed'
        @store       = store
        store.syncdb = syncdb
        @syncdb      = syncdb
        @_client     = client
        @_is_project = client.is_project()  # the project client is designated to manage execution/conflict, etc.
        store._is_project = @_is_project
        @_account_id = client.client_id()   # project or account's id

        @setState
            error               : undefined
            cur_id              : @store.get_local_storage('cur_id')
            toolbar             : not @store.get_local_storage('hide_toolbar')
            has_unsaved_changes : true
            sel_ids             : immutable.Set()  # immutable set of selected cells
            md_edit_ids         : immutable.Set()  # set of ids of markdown cells in edit mode
            mode                : 'escape'
            font_size           : @store.get_local_storage('font_size') ? @redux.getStore('account')?.get('font_size') ? 14
            project_id          : project_id
            directory           : misc.path_split(path)?.head
            path                : path
            is_focused          : false            # whether or not the editor is focused.
            max_output_length   : 10000

        f = () =>
            @setState(has_unsaved_changes : @syncdb?.has_unsaved_changes())
            setTimeout((=>@setState(has_unsaved_changes : @syncdb?.has_unsaved_changes())), 3000)
        @set_has_unsaved_changes = underscore.debounce(f, 1500)

        @syncdb.on('metadata-change', @set_has_unsaved_changes)
        @syncdb.on('change', @_syncdb_change)

        if not client.is_project() # project doesn't care about cursors
            @syncdb.on('cursor_activity', @_syncdb_cursor_activity)

        if not client.is_project() and window?.$?
            # frontend browser client with jQuery
            @set_jupyter_kernels()  # must be after setting project_id above.

            # set codemirror editor options whenever account editor_settings change.
            @redux.getStore('account').on('change', @_account_change)

            @_commands = commands.commands(@)

    _account_change: (state) => # TODO: this is just an ugly hack until we implement redux change listeners for particular keys.
        if not state.get('editor_settings').equals(@_account_change_editor_settings)
            @_account_change_editor_settings = state.get('editor_settings')
            @set_cm_options()

    dbg: (f) =>
        return @_client.dbg("JupyterActions('#{@store.get('path')}').#{f}")

    close: =>
        if @_state == 'closed'
            return
        @set_local_storage('cur_id', @store.get('cur_id'))
        @_state = 'closed'
        @syncdb.close()
        delete @syncdb
        delete @_commands
        if @_key_handler?
            @redux.getActions('page').erase_active_key_handler(@_key_handler)
            delete @_key_handler
        if @_file_watcher?
            @_file_watcher.close()
            delete @_file_watcher
        if not @_is_project
            @redux.getStore('account')?.removeListener('change', @_account_change)

    enable_key_handler: =>
        if @_state == 'closed'
            return
        @_key_handler ?= keyboard.create_key_handler(@)
        @redux.getActions('page').set_active_key_handler(@_key_handler)

    disable_key_handler: =>
        @redux.getActions('page').erase_active_key_handler(@_key_handler)

    _ajax: (opts) =>
        opts = defaults opts,
            url     : required
            timeout : 15000
            cb      : undefined    # (err, data as Javascript object -- i.e., JSON is parsed)
        if not $?
            opts.cb?("_ajax only makes sense in browser")
            return
        $.ajax(
            url     : opts.url
            timeout : opts.timeout
            success : (data) =>
                #try
                    opts.cb?(undefined, JSON.parse(data))
                #catch err
                #    opts.cb?("#{err}")
        ).fail (err) => opts.cb?(err.statusText ? 'error')

    set_jupyter_kernels: =>
        if jupyter_kernels?
            @setState(kernels: jupyter_kernels)
        else
            f = (cb) =>
                if @_state == 'closed'
                    cb(); return
                @_ajax
                    url     : util.get_server_url(@store.get('project_id')) + '/kernels.json'
                    timeout : 3000
                    cb      : (err, data) =>
                        if err
                            cb(err)
                            return
                        try
                            jupyter_kernels = immutable.fromJS(data)
                            @setState(kernels: jupyter_kernels)
                            # We must also update the kernel info (e.g., display name), now that we
                            # know the kernels (e.g., maybe it changed or is now known but wasn't before).
                            @setState(kernel_info: @store.get_kernel_info(@store.get('kernel')))
                            cb()
                        catch e
                            @set_error("Error setting Jupyter kernels -- #{data} #{e}")

            misc.retry_until_success
                f           : f
                start_delay : 1500
                max_delay   : 15000
                max_time    : 60000

    set_error: (err) =>
        if not err?
            @setState(error: undefined)
            return
        cur = @store.get('error')
        if cur
            err = err + '\n\n' + cur
        @setState
            error : err

    # Set the input of the given cell in the syncdb, which will also
    # change the store.
    set_cell_input: (id, input, save=true) =>
        @_set
            type  : 'cell'
            id    : id
            input : input
            start : null
            end   : null,
            save


    set_cell_output: (id, output, save=true) =>
        @_set
            type   : 'cell'
            id     : id
            output : output,
            save

    clear_selected_outputs: =>
        cells = @store.get('cells')
        for id in @store.get_selected_cell_ids_list()
            if cells.get(id).get('output')?
                @_set({type:'cell', id:id, output:null}, false)
        @_sync()

    clear_all_outputs: =>
        @store.get('cells').forEach (cell, id) =>
            if cell.get('output')?
                @_set({type:'cell', id:id, output:null}, false)
            return
        @_sync()

    # prop can be: 'collapsed', 'scrolled'
    toggle_output: (id, prop) =>
        if @store.getIn(['cells', id, 'cell_type']) ? 'code' == 'code'
            @_set(type:'cell', id:id, "#{prop}": not @store.getIn(['cells', id, prop]))

    toggle_selected_outputs: (prop) =>
        cells = @store.get('cells')
        for id in @store.get_selected_cell_ids_list()
            cell = cells.get(id)
            if cell.get('cell_type') ? 'code' == 'code'
                @_set({type:'cell', id:id, "#{prop}": not cell.get(prop)}, false)
        @_sync()

    toggle_all_outputs: (prop) =>
        @store.get('cells').forEach (cell, id) =>
            if cell.get('cell_type') ? 'code' == 'code'
                @_set({type:'cell', id:id, "#{prop}": not cell.get(prop)}, false)
            return
        @_sync()

    set_cell_pos: (id, pos, save=true) =>
        @_set({type: 'cell', id: id, pos: pos}, save)

    set_cell_type: (id, cell_type='code') =>
        if cell_type != 'markdown' and cell_type != 'raw' and cell_type != 'code'
            throw Error("cell type (='#{cell_type}') must be 'markdown', 'raw', or 'code'")
        obj =
            type      : 'cell'
            id        : id
            cell_type : cell_type
        if cell_type != 'code'
            # delete output and exec time info when switching to non-code cell_type
            obj.output = obj.start = obj.end = obj.collapsed = obj.scrolled = null
        @_set(obj)

    set_selected_cell_type: (cell_type) =>
        sel_ids = @store.get('sel_ids')
        cur_id = @store.get('cur_id')
        if sel_ids.size == 0
            if cur_id?
                @set_cell_type(cur_id, cell_type)
        else
            sel_ids.forEach (id) =>
                @set_cell_type(id, cell_type)
                return

    set_md_cell_editing: (id) =>
        md_edit_ids = @store.get('md_edit_ids')
        if md_edit_ids.contains(id)
            return
        @setState(md_edit_ids : md_edit_ids.add(id))

    set_md_cell_not_editing: (id) =>
        md_edit_ids = @store.get('md_edit_ids')
        if not md_edit_ids.contains(id)
            return
        @setState(md_edit_ids : md_edit_ids.delete(id))

    change_cell_to_heading: (id, n=1) =>
        @set_md_cell_editing(id)
        @set_cell_type(id, 'markdown')
        input = misc.lstrip(@_get_cell_input(id))
        i = 0
        while i < input.length and input[i] == '#'
            i += 1
        input = ('#' for _ in [0...n]).join('') + \
            (if not misc.is_whitespace(input[i]) then ' ' else '') + input.slice(i)
        @set_cell_input(id, input)

    # Set which cell is currently the cursor.
    set_cur_id: (id) =>
        @setState(cur_id : id)

    set_cur_id_from_index: (i) =>
        if not i?
            return
        cell_list = @store.get('cell_list')
        if not cell_list?
            return
        if i < 0
            i = 0
        else if i >= cell_list.size
            i = cell_list.size - 1
        @set_cur_id(cell_list.get(i))

    select_cell: (id) =>
        sel_ids = @store.get('sel_ids')
        if sel_ids.contains(id)
            return
        @setState(sel_ids : sel_ids.add(id))

    unselect_cell: (id) =>
        sel_ids = @store.get('sel_ids')
        if not sel_ids.contains(id)
            return
        @setState(sel_ids : sel_ids.remove(id))

    unselect_all_cells: =>
        @setState(sel_ids : immutable.Set())

    select_all_cells: =>
        @setState(sel_ids : @store.get('cell_list').toSet())

    # select all cells from the currently focused one (where the cursor is -- cur_id)
    # to the cell with the given id, then set the cursor to be at id.
    select_cell_range: (id) =>
        cur_id = @store.get('cur_id')
        if not cur_id?
            # no range -- just select the new id
            @set_cur_id(id)
            return
        sel_ids = @store.get('sel_ids')
        if cur_id == id # little to do...
            if sel_ids.size > 0
                @setState(sel_ids : immutable.Set())  # empty (cur_id always included)
            return
        v = @store.get('cell_list').toJS()
        for [i, x] in misc.enumerate(v)
            if x == id
                endpoint0 = i
            if x == cur_id
                endpoint1 = i
        sel_ids = immutable.Set( (v[i] for i in [endpoint0..endpoint1]) )
        @setState
            sel_ids : sel_ids
            cur_id  : id

    extend_selection: (delta) =>
        cur_id = @store.get('cur_id')
        @move_cursor(delta)
        target_id = @store.get('cur_id')
        if cur_id == target_id
            # no move
            return
        sel_ids = @store.get('sel_ids')
        if sel_ids?.get(target_id)
            # moved cursor onto a selected cell
            if sel_ids.size <= 2
                # selection clears if shrinks to 1
                @unselect_all_cells()
            else
                @unselect_cell(cur_id)
        else
            # moved onto a not-selected cell
            @select_cell(cur_id)
            @select_cell(target_id)

    set_mode: (mode) =>
        if mode == 'escape'
            if @store.get('mode') == 'escape'
                return
            # switching from edit to escape mode.
            # save code being typed
            @_get_cell_input()
            # Now switch.
            @setState(mode: mode)
            @set_cursor_locs([])  # none
        else if mode == 'edit'
            if @store.get('mode') == 'edit'
                return
            # from escape to edit
            @setState(mode:mode)
            id = @store.get('cur_id')
            type = @store.getIn(['cells', id, 'cell_type'])
            if type == 'markdown'
                @set_md_cell_editing(id)
        else
            @set_error("unknown mode '#{mode}'")

    set_cell_list: =>
        cells = @store.get('cells')
        if not cells?
            return
        cell_list = util.sorted_cell_list(cells)
        if not cell_list.equals(@store.get('cell_list'))
            @setState(cell_list : cell_list)
        return

    _syncdb_cell_change: (id, new_cell) =>
        if typeof(id) != 'string'
            console.warn("ignoring cell with invalid id='#{JSON.stringify(id)}'")
            return
        cells = @store.get('cells') ? immutable.Map()
        cell_list_needs_recompute = false
        #@dbg("_syncdb_cell_change")("#{id} #{JSON.stringify(new_cell?.toJS())}")
        old_cell = cells.get(id)
        if not new_cell?
            # delete cell
            @reset_more_output(id)  # free up memory locally
            if old_cell?
                obj = {cells: cells.delete(id)}
                cell_list = @store.get('cell_list')
                if cell_list?
                    obj.cell_list = cell_list.filter((x) -> x != id)
                @setState(obj)
        else
            # change or add cell
            old_cell = cells.get(id)
            if new_cell.equals(old_cell)
                return # nothing to do
            if old_cell? and new_cell.get('start') != old_cell.get('start')
                # cell re-evaluated so any more output is no longer valid.
                @reset_more_output(id)
            obj = {cells: cells.set(id, new_cell)}
            if not old_cell? or old_cell.get('pos') != new_cell.get('pos')
                cell_list_needs_recompute = true
            @setState(obj)
        if @_is_project
            @manage_on_cell_change(id, new_cell, old_cell)
        return cell_list_needs_recompute

    _syncdb_change: (changes) =>
        do_init = @_is_project and @_state == 'init'
        #console.log 'changes', changes, changes?.toJS()
        #@dbg("_syncdb_change")(JSON.stringify(changes?.toJS()))
        @set_has_unsaved_changes()
        cell_list_needs_recompute = false
        changes?.forEach (key) =>
            record = @syncdb.get_one(key)
            switch key.get('type')
                when 'cell'
                    if @_syncdb_cell_change(key.get('id'), record)
                        cell_list_needs_recompute = true
                when 'settings'
                    if not record?
                        return
                    orig_kernel = @store.get('kernel')
                    kernel = record.get('kernel')
                    obj =
                        backend_state     : record.get('backend_state')
                        kernel_state      : record.get('kernel_state')
                        max_output_length : bounded_integer(record.get('max_output_length'), 100, 100000, 20000)
                    if kernel != orig_kernel
                        obj.kernel              = kernel
                        obj.kernel_info         = @store.get_kernel_info(kernel)
                        obj.backend_kernel_info = undefined
                    else
                        kernel_changed = false
                    @setState(obj)
                    if not @_is_project and orig_kernel != kernel
                        @set_backend_kernel_info()
                        @set_cm_options()
            return
        if cell_list_needs_recompute
            @set_cell_list()
        cur_id = @store.get('cur_id')
        if not cur_id? or not @store.getIn(['cells', cur_id])?
            @set_cur_id(@store.get('cell_list')?.get(0))

        if do_init
            @initialize_manager()
        else if @_state == 'init'
            @_state = 'ready'

    _syncdb_cursor_activity: =>
        cells = cells_before = @store.get('cells')
        next_cursors = @syncdb.get_cursors()
        next_cursors.forEach (info, account_id) =>
            last_info = @_last_cursors?.get(account_id)
            if last_info?.equals(info)
                # no change for this particular users, so nothing further to do
                return
            # delete old cursor locations
            last_info?.get('locs').forEach (loc) =>
                id = loc.get('id')
                cell = cells.get(id)
                if not cell?
                    return
                cursors = cell.get('cursors') ? immutable.Map()
                if cursors.has(account_id)
                    cells = cells.set(id, cell.set('cursors', cursors.delete(account_id)))
                    return false  # nothing further to do
                return

            # set new cursors
            info.get('locs').forEach (loc) =>
                id = loc.get('id')
                cell = cells.get(id)
                if not cell?
                    return
                cursors = cell.get('cursors') ? immutable.Map()
                loc = loc.set('time', info.get('time')).delete('id')
                locs = (cursors.get(account_id) ? immutable.List()).push(loc)
                cursors = cursors.set(account_id, locs)
                cell = cell.set('cursors', cursors)
                cells = cells.set(id, cell)
                return

        @_last_cursors = next_cursors

        if cells != cells_before
            @setState(cells : cells)

    _set: (obj, save=true) =>
        if @_state == 'closed'
            return
        #@dbg("_set")("obj=#{misc.to_json(obj)}")
        @syncdb.exit_undo_mode()
        @syncdb.set(obj, save)
        # ensure that we update locally immediately for our own changes.
        @_syncdb_change(immutable.fromJS([misc.copy_with(obj, ['id', 'type'])]))

    _delete: (obj, save=true) =>
        if @_state == 'closed'
            return
        @syncdb.exit_undo_mode()
        @syncdb.delete(obj, save)
        @_syncdb_change(immutable.fromJS([{type:obj.type, id:obj.id}]))

    _sync: =>
        if @_state == 'closed'
            return
        @syncdb.sync()

    save: =>
        if @store.get('mode') == 'edit'
            @_get_cell_input()
        # Saves our customer format sync doc-db to disk; the backend will
        # also save the normal ipynb file to disk right after.
        @syncdb.save () =>
            @set_has_unsaved_changes()
        @set_has_unsaved_changes()

    save_asap: =>
        @syncdb.save_asap (err) =>
            if err
                setTimeout((()=>@syncdb.save_asap()), 50)
        return

    _new_id: =>
        return misc.uuid().slice(0,8)  # TODO: choose something...; ensure is unique, etc.

    # TODO: for insert i'm using averaging; for move I'm just resetting all to integers.
    # **should** use averaging but if get close re-spread all properly.  OR use strings?
    insert_cell: (delta) =>  # delta = -1 (above) or +1 (below)
        cur_id = @store.get('cur_id')
        if not cur_id? # TODO
            return
        v = @store.get('cell_list')
        if not v?
            return
        adjacent_id = undefined
        v.forEach (id, i) ->
            if id == cur_id
                j = i + delta
                if j >= 0 and j < v.size
                    adjacent_id = v.get(j)
                return false  # break iteration
            return
        cells = @store.get('cells')
        if adjacent_id?
            adjacent_pos = cells.get(adjacent_id)?.get('pos')
        else
            adjacent_pos = undefined
        current_pos = cells.get(cur_id).get('pos')
        if adjacent_pos?
            pos = (adjacent_pos + current_pos)/2
        else
            pos = current_pos + delta
        new_id = @_new_id()
        @_set
            type  : 'cell'
            id    : new_id
            pos   : pos
            input : ''
        @set_cur_id(new_id)
        return new_id  # technically violates CQRS -- but not from the store.

    delete_selected_cells: (sync=true) =>
        selected = @store.get_selected_cell_ids_list()
        if selected.length == 0
            return
        id = @store.get('cur_id')
        @move_cursor_after(selected[selected.length-1])
        if @store.get('cur_id') == id
            @move_cursor_before(selected[0])
        for id in selected
            @_delete({type:'cell', id:id}, false)
        if sync
            @_sync()
        return

    # move all selected cells delta positions, e.g., delta = +1 or delta = -1
    move_selected_cells: (delta) =>
        if delta == 0
            return
        # This action changes the pos attributes of 0 or more cells.
        selected = @store.get_selected_cell_ids()
        if misc.len(selected) == 0
            return # nothing to do
        v = @store.get('cell_list')
        if not v?
            return  # don't even have cell list yet...
        v = v.toJS()  # javascript array of unique cell id's, properly ordered
        w = []
        # put selected cells in their proper new positions
        for i in [0...v.length]
            if selected[v[i]]
                n = i + delta
                if n < 0 or n >= v.length
                    # would move cells out of document, so nothing to do
                    return
                w[n] = v[i]
        # now put non-selected in remaining places
        k = 0
        for i in [0...v.length]
            if not selected[v[i]]
                while w[k]?
                    k += 1
                w[k] = v[i]
        # now w is a complete list of the id's in the proper order; use it to set pos
        if underscore.isEqual(v, w)
            # no change
            return
        cells = @store.get('cells')
        changes = immutable.Set()
        for pos in [0...w.length]
            id = w[pos]
            if cells.get(id).get('pos') != pos
                @set_cell_pos(id, pos, false)
        @_sync()

    undo: =>
        @syncdb?.undo()
        return

    redo: =>
        @syncdb?.redo()
        return

    run_cell: (id) =>
        cell = @store.getIn(['cells', id])
        if not cell?
            return

        @unselect_all_cells()  # for whatever reason, any running of a cell deselects in official jupyter

        cell_type = cell.get('cell_type') ? 'code'
        switch cell_type
            when 'code'
                code = @_get_cell_input(id).trim()
                switch parsing.run_mode(code, @store.getIn(['cm_options', 'mode', 'name']))
                    when 'show_source'
                        @introspect(code.slice(0,code.length-2), 1)
                    when 'show_doc'
                        @introspect(code.slice(0,code.length-1), 0)
                    when 'empty'
                        @clear_cell(id)
                    when 'execute'
                        @run_code_cell(id)
            when 'markdown'
                @set_md_cell_not_editing(id)
        @save_asap()
        return

    run_code_cell: (id) =>
        @_set
            type         : 'cell'
            id           : id
            state        : 'start'
            start        : null
            end          : null
            output       : null
            exec_count   : null
            collapsed    : null

    clear_cell: (id) =>
        @_set
            type         : 'cell'
            id           : id
            state        : null
            start        : null
            end          : null
            output       : null
            exec_count   : null
            collapsed    : null

    run_selected_cells: =>
        v = @store.get_selected_cell_ids_list()
        for id in v
            @run_cell(id)
        @save_asap()

    # Run the selected cells, by either clicking the play button or
    # press shift+enter.  Note that this has somewhat weird/inconsitent
    # behavior in official Jupyter for usability reasons and due to
    # their "modal" approach.
    # In paricular, if the selections goes to the end of the document, we
    # create a new cell and set it the mode to edit; otherwise, we advance
    # the cursor and switch to escape mode.
    shift_enter_run_selected_cells: =>
        v = @store.get_selected_cell_ids_list()
        if v.length == 0
            return
        last_id = v[v.length-1]

        @run_selected_cells()

        cell_list = @store.get('cell_list')
        if cell_list?.get(cell_list.size-1) == last_id
            @set_cur_id(last_id)
            new_id = @insert_cell(1)
            # this is ugly, but I don't know a better way; when the codemirror editor of
            # the current cell unmounts, it blurs, which happens after right now.
            # So we just change the mode back to edit slightly in the future.
            setTimeout((()=>@set_cur_id(new_id); @set_mode('edit')), 1)
        else
            @set_mode('escape')
            @move_cursor(1)


    run_all_cells: =>
        @store.get('cell_list').forEach (id) =>
            @run_cell(id)
            return
        @save_asap()

    # Run all cells strictly above the current cursor position.
    run_all_above: =>
        i = @store.get_cur_cell_index()
        if not i?
            return
        for id in @store.get('cell_list')?.toJS().slice(0, i)
            @run_cell(id)
        return

    # Run all cells below (and *including*) the current cursor position.
    run_all_below: =>
        i = @store.get_cur_cell_index()
        if not i?
            return
        for id in @store.get('cell_list')?.toJS().slice(i)
            @run_cell(id)
        return

    move_cursor_after_selected_cells: =>
        v = @store.get_selected_cell_ids_list()
        if v.length > 0
            @move_cursor_after(v[v.length-1])

    move_cursor_to_last_selected_cell: =>
        v = @store.get_selected_cell_ids_list()
        if v.length > 0
            @set_cur_id(v[v.length-1])

    # move cursor delta positions from current position
    move_cursor: (delta) =>
        @set_cur_id_from_index(@store.get_cur_cell_index() + delta)
        return

    move_cursor_after: (id) =>
        i = @store.get_cell_index(id)
        if not i?
            return
        @set_cur_id_from_index(i + 1)
        return

    move_cursor_before: (id) =>
        i = @store.get_cell_index(id)
        if not i?
            return
        @set_cur_id_from_index(i - 1)
        return

    set_cursor_locs: (locs=[]) =>
        if locs.length == 0
            # don't remove on blur -- cursor will fade out just fine
            return
        @_cursor_locs = locs  # remember our own cursors for splitting cell
        @syncdb.set_cursor_locs(locs)

    split_current_cell: =>
        cursor = @_cursor_locs?[0]
        if not cursor?
            return
        if cursor.id != @store.get('cur_id')
            # cursor isn't in currently selected cell, so don't know how to split
            return
        # insert a new cell before the currently selected one
        new_id = @insert_cell(-1)

        # split the cell content at the cursor loc
        cell = @store.get('cells').get(cursor.id)
        if not cell?
            return  # this would be a bug?
        cell_type = cell.get('cell_type')
        if cell_type != 'code'
            @set_cell_type(new_id, cell_type)
            @set_md_cell_editing(new_id)
        input = cell.get('input')
        if not input?
            return

        lines  = input.split('\n')
        v      = lines.slice(0, cursor.y)
        line   = lines[cursor.y]
        left = line.slice(0, cursor.x)
        if left
            v.push(left)
        top = v.join('\n')

        v     = lines.slice(cursor.y+1)
        right = line.slice(cursor.x)
        if right
            v = [right].concat(v)
        bottom = v.join('\n')
        @set_cell_input(new_id, top, false)
        @set_cell_input(cursor.id, bottom, true)
        @set_cur_id(cursor.id)

    # Copy content from the cell below the current cell into the currently
    # selected cell, then delete the cell below the current cell.s
    merge_cell_below: (save=true) =>
        cur_id = @store.get('cur_id')
        if not cur_id?
            return
        next_id = @store.get_cell_id(1)
        if not next_id?
            return
        cells = @store.get('cells')
        if not cells?
            return
        input  = (cells.get(cur_id)?.get('input') ? '') + '\n' + (cells.get(next_id)?.get('input') ? '')

        output = undefined
        output0 = cells.get(cur_id)?.get('output')
        output1 = cells.get(next_id)?.get('output')
        if not output0?
            output = output1
        else if not output1?
            output = output0
        else
            # both output0 and output1 are defined; need to merge.
            # This is complicated since output is a map from string numbers.
            output = output0
            n = output0.size
            for i in [0...output1.size]
                output = output.set("#{n}", output1.get("#{i}"))
                n += 1

        @_delete({type:'cell', id:next_id}, false)
        @_set
            type   : 'cell'
            id     : cur_id
            input  : input
            output : output ? null
            start  : null
            end    : null,
            save
        return

    merge_cell_above: =>
        @move_cursor(-1)
        @merge_cell_below()
        return

    # Merge all selected cells into one cell.
    # We also merge all output, instead of throwing away
    # all but first output (which jupyter does, and makes no sense).
    merge_cells: =>
        v = @store.get_selected_cell_ids_list()
        n = v?.length
        if not n? or n <= 1
            return
        @set_cur_id(v[0])
        for i in [0...n-1]
            @merge_cell_below(i == n-2)

    # Copy all currently selected cells into our internal clipboard
    copy_selected_cells: =>
        cells = @store.get('cells')
        global_clipboard = immutable.List()
        for id in @store.get_selected_cell_ids_list()
            global_clipboard = global_clipboard.push(cells.get(id))
        @store.set_global_clipboard(global_clipboard)
        return

    # Cut currently selected cells, putting them in internal clipboard
    cut_selected_cells: =>
        @copy_selected_cells()
        @delete_selected_cells()

    # Javascript array of num equally spaced positions starting after before_pos and ending
    # before after_pos, so
    #   [before_pos+delta, before_pos+2*delta, ..., after_pos-delta]
    _positions_between: (before_pos, after_pos, num) =>
        if not before_pos?
            if not after_pos?
                pos = 0
                delta = 1
            else
                pos = after_pos - num
                delta = 1
        else
            if not after_pos?
                pos = before_pos + 1
                delta = 1
            else
                delta = (after_pos - before_pos) / (num + 1)
                pos = before_pos + delta
        v = []
        for i in [0...num]
            v.push(pos)
            pos += delta
        return v

    # Paste cells from the internal clipboard; also
    #   delta = 0 -- replace currently selected cells
    #   delta = 1 -- paste cells below last selected cell
    #   delta = -1 -- paste cells above first selected cell
    paste_cells: (delta=1) =>
        cells = @store.get('cells')
        v = @store.get_selected_cell_ids_list()
        if v.length == 0
            return # no selected cells
        if delta == 0 or delta == -1
            cell_before_pasted_id = @store.get_cell_id(-1, v[0])  # one before first selected
        else if delta == 1
            cell_before_pasted_id = v[v.length-1]                 # last selected
        else
            console.warn("paste_cells: invalid delta=#{delta}")
            return
        try
            if delta == 0
                # replace, so delete currently selected, unless just the cursor, since
                # cursor vs selection is confusing with Jupyer's model.
                if v.length > 1
                    @delete_selected_cells(false)
            clipboard = @store.get_global_clipboard()
            if not clipboard? or clipboard.size == 0
                return   # nothing more to do
            # put the cells from the clipboard into the document, setting their positions
            if not cell_before_pasted_id?
                # very top cell
                before_pos = undefined
                after_pos  = cells.getIn([v[0], 'pos'])
            else
                before_pos = cells.getIn([cell_before_pasted_id, 'pos'])
                after_pos  = cells.getIn([@store.get_cell_id(+1, cell_before_pasted_id), 'pos'])
            positions = @_positions_between(before_pos, after_pos, clipboard.size)
            clipboard.forEach (cell, i) =>
                cell = cell.set('id', @_new_id())   # randomize the id of the cell
                cell = cell.set('pos', positions[i])
                @_set(cell, false)
                return
        finally
            # very important that we save whatever is done above, so other viewers see it.
            @_sync()

    toggle_toolbar: =>
        @set_toolbar_state(not @store.get('toolbar'))

    set_toolbar_state: (val) =>  # val = true = visible
        @setState(toolbar: val)
        @set_local_storage('hide_toolbar', not val)

    toggle_header: =>
        @redux?.getActions('page').toggle_fullscreen()

    set_header_state: (val) =>
        @redux?.getActions('page').set_fullscreen(val)

    set_line_numbers: (show) =>
        @set_local_storage('line_numbers', !!show)
        # unset the line_numbers property from all cells
        cells = @store.get('cells').map((cell) -> cell.delete('line_numbers'))
        if not cells.equals(@store.get('cells'))
            # actually changed
            @setState(cells: cells)
        # now cause cells to update
        @set_cm_options()
        return

    toggle_line_numbers: =>
        @set_line_numbers(not @store.get_local_storage('line_numbers'))

    toggle_cell_line_numbers: (id) =>
        cells = @store.get('cells')
        cell = cells.get(id)
        if not cell?
            return
        line_numbers = cell.get('line_numbers') ? @store.get_local_storage('line_numbers') ? false
        @setState(cells: cells.set(id, cell.set('line_numbers', not line_numbers)))

    # zoom in or out delta font sizes
    set_font_size: (pixels) =>
        @setState
            font_size : pixels
        # store in localStorage
        @set_local_storage('font_size', pixels)

    set_local_storage: (key, value) =>
        if localStorage?
            current = localStorage[@name]
            if current?
                current = misc.from_json(current)
            else
                current = {}
            if value == null
                delete current[key]
            else
                current[key] = value
            localStorage[@name] = misc.to_json(current)

    zoom: (delta) =>
        @set_font_size(@store.get('font_size') + delta)

    set_scroll_state: (state) =>
        @set_local_storage('scroll', state)

    # File --> Open: just show the file listing page.
    file_open: =>
        @redux?.getProjectActions(@store.get('project_id')).set_active_tab('files')
        return

    file_new: =>
        @redux?.getProjectActions(@store.get('project_id')).set_active_tab('new')
        return

    register_input_editor: (id, save_value) =>
        @_input_editors ?= {}
        @_input_editors[id] = save_value
        return
    unregister_input_editor: (id) =>
        delete @_input_editors?[id]
    # Meant to be used for implementing actions -- do not call externally
    _get_cell_input: (id) =>
        id ?= @store.get('cur_id')
        return (@_input_editors?[id]?() ? @store.getIn(['cells', id, 'input']) ? '')

    set_kernel: (kernel) =>
        if @store.get('kernel') != kernel
            @_set
                type     : 'settings'
                kernel   : kernel

    show_history_viewer: () =>
        @redux.getProjectActions(@store.get('project_id'))?.open_file
            path       : misc.history_path(@store.get('path'))
            foreground : true

    # Attempt to fetch completions for give code and cursor_pos
    # If successful, the completions are put in store.get('completions') and looks like
    # this (as an immutable map):
    #    cursor_end   : 2
    #    cursor_start : 0
    #    matches      : ['the', 'completions', ...]
    #    status       : "ok"
    #    code         : code
    #    cursor_pos   : cursor_pos
    #
    # If not successful, result is:
    #    status       : "error"
    #    code         : code
    #    cursor_pos   : cursor_pos
    #    error        : 'an error message'
    #
    # Only the most recent fetch has any impact, and calling
    # clear_complete() ensures any fetch made before that
    # is ignored.
    complete: (code, pos, id, offset) =>
        req = @_complete_request = (@_complete_request ? 0) + 1

        @setState(complete: undefined)

        # pos can be either a {line:?, ch:?} object as in codemirror,
        # or a number.
        if misc.is_object(pos)
            lines = code.split('\n')
            cursor_pos = misc.sum(lines[i].length+1 for i in [0...pos.line]) + pos.ch
        else
            cursor_pos = pos

        @_ajax
            url     : util.get_complete_url(@store.get('project_id'), @store.get('path'), code, cursor_pos)
            timeout : 5000
            cb      : (err, data) =>
                if @_complete_request > req
                    # future completion or clear happened; so ignore this result.
                    return
                if err
                    complete = {error  : err}
                else
                    complete = data
                    if complete.status != 'ok'
                        complete = {error:'completion failed'}
                    delete complete.status
                # Set the result so the UI can then react to the change.
                if complete?.matches?.length == 0
                    # do nothing -- no completions at all
                    return
                if offset?
                    complete.offset = offset
                @setState(complete: immutable.fromJS(complete))
                if complete?.matches?.length == 1 and id?
                    # special case -- a unique completion and we know id of cell in which completing is given
                    @select_complete(id, complete.matches[0])
                    return
        return

    clear_complete: =>
        @_complete_request = (@_complete_request ? 0) + 1
        @setState(complete: undefined)

    select_complete: (id, item) =>
        complete = @store.get('complete')
        input    = @store.getIn(['cells', id, 'input'])
        @clear_complete()
        @set_mode('edit')
        if complete? and input? and not complete.get('error')?
            new_input = input.slice(0, complete.get('cursor_start')) + item + input.slice(complete.get('cursor_end'))
            # We don't actually make the completion until the next render loop,
            # so that the editor is already in edit mode.  This way the cursor is
            # in the right position after making the change.
            setTimeout((=> @set_cell_input(id, new_input)), 0)

    introspect: (code, level, cursor_pos) =>
        req = @_introspect_request = (@_introspect_request ? 0) + 1

        @setState(introspect: undefined)

        cursor_pos ?= code.length

        @_ajax
            url     : util.get_introspect_url(@store.get('project_id'), @store.get('path'), code, cursor_pos, level)
            timeout : 30000
            cb      : (err, data) =>
                if @_introspect_request > req
                    # future completion or clear happened; so ignore this result.
                    return
                if err
                    introspect = {error  : err}
                else
                    introspect = data
                    if introspect.status != 'ok'
                        introspect = {error:'completion failed'}
                    delete introspect.status

                @setState(introspect: immutable.fromJS(introspect))
        return

    clear_introspect: =>
        @_introspect_request = (@_introspect_request ? 0) + 1
        @setState(introspect: undefined)

    signal: (signal='SIGINT') =>
        @_ajax
            url     : util.get_signal_url(@store.get('project_id'), @store.get('path'), signal)
            timeout : 5000
        return

    set_backend_kernel_info: =>
        if @_fetching_backend_kernel_info
            return
        if @store.get('backend_kernel_info')?
            return
        @_fetching_backend_kernel_info = true
        f = (cb) =>
            @_ajax
                url     : util.get_kernel_info_url(@store.get('project_id'), @store.get('path'))
                timeout : 15000
                cb      : (err, data) =>
                    if err
                        console.log("Error setting backend kernel info -- #{err}")
                        cb(true)
                    else
                        if data.error?
                            console.log("Error setting backend kernel info -- #{data.error}")
                            cb(true)
                        else
                            @_fetching_backend_kernel_info = false
                            @setState(backend_kernel_info: immutable.fromJS(data))
                            # this is when the server for this doc started, not when kernel last started!
                            @setState(start_time : data.start_time)
                            # Update the codemirror editor options.
                            @set_cm_options()
        misc.retry_until_success
            f           : f
            max_time    : 60000
            start_delay : 3000
            max_delay   : 10000

    # Do a file action, e.g., 'compress', 'delete', 'rename', 'duplicate', 'move',
    # 'copy', 'share', 'download'.  Each just shows the corresponding dialog in
    # the file manager, so gives a step to confirm, etc.
    file_action: (action_name) =>
        a = @redux.getProjectActions(@store.get('project_id'))
        path = @store.get('path')
        if action_name == 'close_file'
            a.close_file(path)
            return
        {head, tail} = misc.path_split(path)
        a.open_directory(head)
        a.set_all_files_unchecked()
        a.set_file_checked(@store.get('path'), true)
        a.set_file_action(action_name, -> tail)

    show_about: =>
        @setState(about:true)
        @set_backend_kernel_info()

    focus: (wait) =>
        #console.log 'focus', wait, (new Error()).stack
        if @_state == 'closed'
            return
        if @_blur_lock
            return
        if wait
            setTimeout(@focus, 1)
        else
            @setState(is_focused: true)

    blur: (wait) =>
        if @_state == 'closed'
            return
        if wait
            setTimeout(@blur, 1)
        else
            @setState
                is_focused : false
                mode       : 'escape'

    blur_lock: =>
        @blur()
        @_blur_lock = true

    focus_unlock: =>
        @_blur_lock = false
        @focus()

    set_max_output_length: (n) =>
        @_set
            type              : 'settings'
            max_output_length : n

    fetch_more_output: (id) =>
        time = @_client.server_time() - 0
        @_ajax
            url     : util.get_more_output_url(@store.get('project_id'), @store.get('path'), id)
            timeout : 60000
            cb      : (err, more_output) =>
                if err
                    @set_error(err)
                else
                    if not @store.getIn(['cells', id, 'scrolled'])
                        # make output area scrolled, since there is going to be a lot of output
                        @toggle_output(id, 'scrolled')
                    @set_more_output(id, {time:time, mesg_list:more_output})

    set_more_output: (id, more_output) =>
        if not @store.getIn(['cells', id])?
            return
        x = @store.get('more_output') ? immutable.Map()
        @setState(more_output : x.set(id, immutable.fromJS(more_output)))

    reset_more_output: (id) =>
        more_output = @store.get('more_output') ? immutable.Map()
        if more_output.has(id)
            @setState(more_output : more_output.delete(id))

    set_cm_options: =>
        mode             = @store.getIn(['backend_kernel_info', 'language_info', 'codemirror_mode'])
        if typeof(mode) == 'string'
            mode = {name:mode}  # some kernels send a string back for the mode; others an object
        else if mode?.toJS?
            mode = mode.toJS()
        else if not mode?
            mode = @store.get('kernel')   # may be better than nothing...; e.g., octave kernel has no mode.
        editor_settings  = @redux.getStore('account')?.get('editor_settings')?.toJS?()
        line_numbers = @store.get_local_storage('line_numbers')
        x = immutable.fromJS
            options  : cm_options(mode, editor_settings, line_numbers)
            markdown : cm_options({name:'gfm2'}, editor_settings, line_numbers)

        if not x.equals(@store.get('cm_options'))  # actually changed
            @setState(cm_options: x)

    show_find_and_replace: =>
        @blur_lock()
        @setState(find_and_replace:{show:true})

    close_find_and_replace: =>
        @setState(find_and_replace:undefined)
        @focus_unlock()

    show_keyboard_shortcuts: =>
        @blur_lock()
        @setState(keyboard_shortcuts:{show:true})

    close_keyboard_shortcuts: =>
        @setState(keyboard_shortcuts:undefined)
        @focus_unlock()

    # Display a confirmation dialog, then call opts.cb with the choice.
    # See confirm-dialog.cjsx for options.
    confirm_dialog: (opts) =>
        @blur_lock()
        @setState(confirm_dialog : opts)
        @store.wait
            until   : (state) =>
                c = state.get('confirm_dialog')
                if not c?  # deleting confirm_dialog prop is same as cancelling.
                    return 'cancel'
                else
                    return c.get('choice')
            timeout : 0
            cb      : (err, choice) =>
                @focus_unlock()
                opts.cb(choice)

    close_confirm_dialog: (choice) =>
        if not choice?
            @setState(confirm_dialog: undefined)
        else
            confirm_dialog = @store.get('confirm_dialog')
            if confirm_dialog?
                @setState(confirm_dialog: confirm_dialog.set('choice', choice))

    trust_notebook: =>
        # TODO:...
        @setState(trust: true)
        @set_error("trust_notebook not implemented")

    insert_image: =>
        # TODO -- this will bring up dialog with button to select file (use dropzone); on selection
        # it will send to backend, etc.... and end up displayed in cell somehow.
        @set_error("insert_image not implemented")

    command: (name) =>
        f = @_commands?[name]?.f
        if f?
            f()
        else
            @set_error("Command '#{name}' is not implemented")
        return

    # if cell is being edited, use this to move the cursor *in that cell*
    move_edit_cursor: (delta) =>
        @set_error('move_edit_cursor not implemented')

    # # supported scroll positions are in commands.coffee
    scroll: (pos) =>
        @setState(scroll: pos)

    print_preview: =>
        console.log("print_preview -- TODO")




