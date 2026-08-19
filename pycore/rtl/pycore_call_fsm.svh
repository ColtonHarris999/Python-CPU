// pycore_call_fsm.svh - S_CALL / S_RETURN arms (included inside pycore_core).
//
// CALL phase map:
//   0  : POS: bases from oparg; RF = callable
//         KW: RF = names tuple → KW_NAMES (16)
//         EX: RF = kwargs TOS → EX_KW (17)
//   1  : CODE_OBJECT → 2; OBJECT → 8; else CALL_FILTER
//   2  : sentinel NULL → free (eff=n_pos or oparg); else method;
//        start entry_slot → 3
//   3-5: code fields entry_slot / co_consts / co_names
//   6  : metadata; start co_defaults → 14
//   7  : frame push + init
//   8-11: BOUND_METHOD unwrap (NULL sentinel required) → join 3
//   12 : TYPE instantiate + __init__ lookup (call_sub_r) → 3 or DONE
//   13 : OBK_BUILTIN - max/len/range on-core; else PY_TRAP_BUILTIN_CALL
//   14 : POS defaults fill, or KW/EX_KW shared binder → 7
//   15 : CALL_PHASE_DONE
//   16 : KW_NAMES — latch names tuple, pop, set POS-like bases → 1
//   17 : EX_KW — NULL → args-only; DICT → kwargs; pop → 18
//   18 : EX_ARGS — latch LIST/TUPLE args; expand or join CALL → 0/19
//   19 : EX_EXPAND — push args elements onto stack → join CALL
                // ----------------------------------------------------------
                // S_CALL: generalized CPython CALL (free / method / BM / TYPE).
                //
                //   Free-function layout (sentinel NULL):
                //     callable @ RF[tos - oparg - 2]
                //     null     @ RF[tos - oparg - 1]
                //     args     @ RF[tos - oparg .. tos - 1]
                //   Method-form layout (LOAD_ATTR method_flag=1):
                //     callable @ RF[tos - oparg - 2]
                //     self     @ RF[tos - oparg - 1]   // non-NULL
                //     args     @ RF[tos - oparg .. tos - 1]
                // ----------------------------------------------------------
                S_CALL: begin
                    if (container_dmem_pending_r && dmem_ack_i) begin
                        container_dmem_pending_r <= 1'b0;
                        container_rd_data_r      <= dmem_rdata_i;
                    end

                    unique case (call_phase_r)

                        5'd0: begin
                            if (call_mode_r == CALL_MODE_KW) begin
                                // TOS = names tuple; settle RF before latch.
                                container_rf_addr_r <= RF_AW'(
                                    {2'b0, tos_r} - 9'd1);
                                call_phase_r <= CALL_PHASE_KW_NAMES;
                            end else if (call_mode_r == CALL_MODE_EX) begin
                                container_rf_addr_r <= RF_AW'(
                                    {2'b0, tos_r} - 9'd1);
                                call_phase_r <= CALL_PHASE_EX_KW;
                            end else begin
                                // Bases from oparg (positional args excluding self).
                                call_new_locals_r <= RF_AW'(
                                    {2'b0, tos_r} - {2'b0, cur_arg_r[6:0]});
                                call_tos_base_r   <= RF_AW'(
                                    {2'b0, tos_r} - {2'b0, cur_arg_r[6:0]} - 9'd2);
                                container_rf_addr_r <= RF_AW'(
                                    {2'b0, tos_r} - {2'b0, cur_arg_r[6:0]} - 9'd2);
                                call_phase_r <= 5'd1;
                            end
                        end

                        5'd1: begin
                            // Callable: CODE_OBJECT or OBJECT (BM / TYPE).
                            if (cont_rf_rs1_tag == PY_TAG_CODE_OBJECT) begin
                                call_code_addr_r    <= cont_rf_rs1_val[31:0];
                                container_rf_addr_r <= RF_AW'(
                                    {2'b0, tos_r} - {2'b0, cur_arg_r[6:0]} - 9'd1);
                                call_phase_r        <= 5'd2;
                            end else if (cont_rf_rs1_tag == PY_TAG_OBJECT) begin
                                call_obj_addr_r     <= cont_rf_rs1_val[31:0];
                                container_rf_addr_r <= RF_AW'(
                                    {2'b0, tos_r} - {2'b0, cur_arg_r[6:0]} - 9'd1);
                                call_sub_r          <= 6'd0;
                                call_phase_r        <= 5'd8;
                            end else begin
                                call_filter_trap_r <= 1'b1;
                            end
                        end

                        5'd2: begin
                            // Sentinel: NULL ⇒ free-function; else method form.
                            // KW/EX_KW: effective positional count is call_n_pos_r.
                            if (pycore_is_null(
                                    cont_rf_rs1_tag, cont_rf_rs1_val)) begin
                                if ((call_mode_r == CALL_MODE_KW) ||
                                    (call_mode_r == CALL_MODE_EX_KW))
                                    call_argcount_r <= {8'b0, call_n_pos_r};
                                else begin
                                    call_argcount_r <= cur_arg_r[15:0];
                                    call_n_pos_r    <= cur_arg_r[7:0];
                                end
                            end else begin
                                if ((call_mode_r == CALL_MODE_KW) ||
                                    (call_mode_r == CALL_MODE_EX_KW))
                                    call_argcount_r <=
                                        {8'b0, call_n_pos_r} + 16'd1;
                                else begin
                                    call_argcount_r <=
                                        cur_arg_r[15:0] + 16'd1;
                                    call_n_pos_r    <= cur_arg_r[7:0];
                                end
                                call_new_locals_r <= RF_AW'(
                                    {2'b0, tos_r} - {2'b0, cur_arg_r[6:0]} - 9'd1);
                            end
                            container_dmem_addr_r    <= pycore_code_field_val_addr(
                                call_code_addr_r, PYCORE_CODE_FIELD_ENTRY_SLOT);
                            container_dmem_we_r      <= 1'b0;
                            container_dmem_pending_r <= 1'b1;
                            call_phase_r             <= 5'd3;
                        end

                        4'd3: begin
                            if (!container_dmem_pending_r) begin
                                call_entry_slot_r <= container_rd_data_r[63:0];
                                container_dmem_addr_r    <= pycore_code_field_val_addr(
                                    call_code_addr_r, PYCORE_CODE_FIELD_CO_CONSTS);
                                container_dmem_we_r      <= 1'b0;
                                container_dmem_pending_r <= 1'b1;
                                call_phase_r             <= 4'd4;
                            end
                        end

                        4'd4: begin
                            if (!container_dmem_pending_r) begin
                                call_consts_r <= container_rd_data_r;
                                container_dmem_addr_r    <= pycore_code_field_val_addr(
                                    call_code_addr_r, PYCORE_CODE_FIELD_CO_NAMES);
                                container_dmem_we_r      <= 1'b0;
                                container_dmem_pending_r <= 1'b1;
                                call_phase_r             <= 4'd5;
                            end
                        end

                        4'd5: begin
                            if (!container_dmem_pending_r) begin
                                call_names_r <= container_rd_data_r;
                                container_dmem_addr_r    <= pycore_code_field_val_addr(
                                    call_code_addr_r, PYCORE_CODE_FIELD_METADATA);
                                container_dmem_we_r      <= 1'b0;
                                container_dmem_pending_r <= 1'b1;
                                call_phase_r             <= 4'd6;
                            end
                        end

                        4'd6: begin
                            if (!container_dmem_pending_r) begin
                                call_meta_argc_r <= pycore_code_meta_argcount(
                                    container_rd_data_r);
                                call_nlocals_r   <= pycore_code_meta_nlocals(
                                    container_rd_data_r);
                                call_kwonly_r <= pycore_code_meta_kwonlyargcount(
                                    container_rd_data_r);
                                call_varargs_r <= pycore_code_meta_varargs(
                                    container_rd_data_r);
                                call_varkw_r <= pycore_code_meta_varkeywords(
                                    container_rd_data_r);
                                call_posonly_r <=
                                    pycore_code_meta_posonlyargcount(
                                        container_rd_data_r);
                                call_total_params_r <=
                                    pycore_code_meta_argcount(container_rd_data_r)
                                    + pycore_code_meta_kwonlyargcount(
                                        container_rd_data_r);
                                // Fresh **kwargs bookkeeping for this call.
                                call_varkw_left_r    <= 128'd0;
                                call_varkw_step_r    <= 5'd0;
                                call_varkw_alloced_r <= 1'b0;
                                container_dmem_addr_r    <= pycore_code_field_val_addr(
                                    call_code_addr_r, PYCORE_CODE_FIELD_CO_DEFAULTS);
                                container_dmem_we_r      <= 1'b0;
                                container_dmem_pending_r <= 1'b1;
                                // KW / EX_KW enter binder at sub 32.  POS calls
                                // with kw-only locals use the same defaults path.
                                // CO_VARKEYWORDS also forces the binder: even a
                                // purely positional call must install the (then
                                // empty) **kwargs dict local.
                                if ((call_mode_r == CALL_MODE_KW) ||
                                    (call_mode_r == CALL_MODE_EX_KW) ||
                                    pycore_code_meta_varkeywords(
                                        container_rd_data_r) ||
                                    (pycore_code_meta_kwonlyargcount(
                                        container_rd_data_r) != 16'd0))
                                    call_sub_r <= 6'd32;
                                else
                                    call_sub_r <= 6'd0;
                                call_phase_r <= 4'd14;
                            end
                        end

                        4'd7: begin
                            if (!call_sent_r && !frame_busy) begin
                                frame_call_valid_r   <= 1'b1;
                                call_sent_r          <= 1'b1;
                            end

                            if (call_sent_r && frame_push_req && !frame_dmem_pending_r) begin
                                frame_dmem_pending_r <= 1'b1;
                            end

                            if (frame_dmem_pending_r && dmem_ack_i) begin
                                frame_dmem_pending_r <= 1'b0;
                            end

                            if (frame_init_new_frame) begin
                                cur_locals_base_r    <= frame_next_locals_base;
                                rf_set_locals_r      <= 1'b1;
                                rf_new_locals_r      <= frame_next_locals_base;
                                // UNINIT-clear only unfilled locals
                                // [call_argcount, nlocals). Filled args /
                                // defaults / *args must survive — the old
                                // (argc==0) wipe of all 32 slots erased
                                // co_defaults after phase-14 fill (tuple(),
                                // f(x=None), etc.).
                                rf_init_frame_r      <=
                                    (call_argcount_r < call_nlocals_r);
                                rf_init_from_r       <= call_argcount_r[RF_AW-1:0];
                                rf_init_until_r      <= call_nlocals_r[RF_AW-1:0];
                                tos_r                <= frame_next_locals_base
                                                        + call_nlocals_r[6:0];
                                call_sent_r          <= 1'b0;
                                frame_dmem_pending_r <= 1'b0;
                                cur_code_r           <= call_code_addr_r;
                                consts_base_r        <= call_consts_r;
                                names_base_r         <= call_names_r;
                                // Live ret-mode for the frame just entered.
                                frame_ret_mode_r     <= call_ret_mode_r;
                                frame_saved_inst_r   <= call_saved_inst_r;
                                redirect_pending_r   <= 1'b1;
                                redirect_tgt_r       <= call_entry_slot_r[31:0];
                                call_phase_r         <= CALL_PHASE_DONE;
                            end
                        end

                        // --------------------------------------------------
                        // Phases 8-11: OBJECT → BOUND_METHOD unwrap
                        // --------------------------------------------------
                        4'd8: begin
                            // Sentinel must be NULL for BM / TYPE calls.
                            if (!pycore_is_null(
                                    cont_rf_rs1_tag, cont_rf_rs1_val)) begin
                                call_filter_trap_r <= 1'b1;
                            end else begin
                                container_dmem_addr_r    <= call_obj_addr_r;
                                container_dmem_we_r      <= 1'b0;
                                container_dmem_pending_r <= 1'b1;
                                call_phase_r             <= 4'd9;
                            end
                        end

                        4'd9: begin
                            if (!container_dmem_pending_r) begin
                                if (pycore_ob_kind(container_rd_data_r) ==
                                        PY_OBK_BOUND_METHOD) begin
                                    container_dmem_addr_r <=
                                        pycore_obj_field_val_addr(
                                            call_obj_addr_r, 32'd0);
                                    container_dmem_we_r      <= 1'b0;
                                    container_dmem_pending_r <= 1'b1;
                                    call_sub_r               <= 6'd0;
                                    call_phase_r             <= 4'd10;
                                end else if (pycore_ob_kind(container_rd_data_r) ==
                                             PY_OBK_TYPE) begin
                                    // Keyword TYPE construction is out of scope.
                                    if ((call_mode_r == CALL_MODE_KW) ||
                                        (call_mode_r == CALL_MODE_EX_KW))
                                        call_filter_trap_r <= 1'b1;
                                    else begin
                                        call_sub_r   <= 6'd0;
                                        call_phase_r <= 4'd12;
                                    end
                                end else if (pycore_ob_kind(container_rd_data_r) ==
                                             PY_OBK_BUILTIN) begin
                                    // Builtins stay positional-only in v1.
                                    if ((call_mode_r == CALL_MODE_KW) ||
                                        (call_mode_r == CALL_MODE_EX_KW))
                                        call_filter_trap_r <= 1'b1;
                                    else begin
                                        container_dmem_addr_r <=
                                            pycore_obj_field_val_addr(
                                                call_obj_addr_r, 32'd0);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r               <= 6'd0;
                                        call_phase_r             <= 4'd13;
                                    end
                                end else begin
                                    call_filter_trap_r <= 1'b1;
                                end
                            end
                        end

                        4'd10: begin
                            // field0 (__func__) val then tag.
                            if (!container_dmem_pending_r) begin
                                if (call_sub_r == 6'd0) begin
                                    call_code_addr_r <= container_rd_data_r[31:0];
                                    container_dmem_addr_r <=
                                        pycore_obj_field_tag_addr(
                                            call_obj_addr_r, 32'd0);
                                    container_dmem_we_r      <= 1'b0;
                                    container_dmem_pending_r <= 1'b1;
                                    call_sub_r               <= 6'd1;
                                end else begin
                                    if (container_rd_data_r[3:0] !=
                                            PY_TAG_CODE_OBJECT) begin
                                        call_filter_trap_r <= 1'b1;
                                    end else begin
                                        container_dmem_addr_r <=
                                            pycore_obj_field_val_addr(
                                                call_obj_addr_r, 32'd1);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r               <= 6'd0;
                                        call_phase_r             <= 4'd11;
                                    end
                                end
                            end
                        end

                        4'd11: begin
                            // field1 (__self__) val/tag; install method form; → 3.
                            if (!container_dmem_pending_r) begin
                                if (call_sub_r == 6'd0) begin
                                    call_self_val_r <= container_rd_data_r;
                                    container_dmem_addr_r <=
                                        pycore_obj_field_tag_addr(
                                            call_obj_addr_r, 32'd1);
                                    container_dmem_we_r      <= 1'b0;
                                    container_dmem_pending_r <= 1'b1;
                                    call_sub_r               <= 6'd1;
                                end else if (call_sub_r == 6'd1) begin
                                    call_self_tag_r <= container_rd_data_r[3:0];
                                    // Overwrite NULL sentinel with __self__.
                                    container_wb_we_r   <= 1'b1;
                                    container_wb_addr_r <= RF_AW'(
                                        {2'b0, tos_r} - {2'b0, cur_arg_r[6:0]}
                                        - 9'd1);
                                    container_wb_data_r <= pycore_make_entry(
                                        container_rd_data_r[3:0], call_self_val_r);
                                    if ((call_mode_r == CALL_MODE_KW) ||
                                        (call_mode_r == CALL_MODE_EX_KW))
                                        call_argcount_r <=
                                            {8'b0, call_n_pos_r} + 16'd1;
                                    else begin
                                        call_argcount_r <=
                                            cur_arg_r[15:0] + 16'd1;
                                        call_n_pos_r    <= cur_arg_r[7:0];
                                    end
                                    call_new_locals_r <= RF_AW'(
                                        {2'b0, tos_r} - {2'b0, cur_arg_r[6:0]}
                                        - 9'd1);
                                    call_sub_r        <= 6'd2;
                                end else begin
                                    container_dmem_addr_r    <=
                                        pycore_code_field_val_addr(
                                            call_code_addr_r,
                                            PYCORE_CODE_FIELD_ENTRY_SLOT);
                                    container_dmem_we_r      <= 1'b0;
                                    container_dmem_pending_r <= 1'b1;
                                    call_sub_r               <= 6'd0;
                                    call_phase_r             <= 4'd3;
                                end
                            end
                        end


                        // --------------------------------------------------
                        // Phase 13: OBK_BUILTIN dispatch
                        //   sub0: latch builtin_id (field0 val), read field0 tag
                        //   sub1: confirm INT id; read field1 (bound_self) val
                        //   sub2: read bound_self tag; branch by id
                        //   sub4-5: MAX - read args; compare; writeback
                        //   sub6-8: LEN - builtin containers / strings / inline range
                        //   sub40-51: LEN - INSTANCE.__len__ own tp_dict probe
                        //   sub12-23: RANGE - normalize args, allocate object
                        //   else: marshal PY_TRAP_BUILTIN_CALL
                        // --------------------------------------------------
                        4'd13: begin
                            unique case (call_sub_r)
                                6'd0: begin
                                    if (!container_dmem_pending_r) begin
                                        call_entry_slot_r[31:0] <= container_rd_data_r[31:0]; // id
                                        container_dmem_addr_r <=
                                            pycore_obj_field_tag_addr(
                                                call_obj_addr_r, 32'd0);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r               <= 6'd1;
                                    end
                                end
                                6'd1: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_rd_data_r[3:0] != PY_TAG_INT) begin
                                            call_filter_trap_r <= 1'b1;
                                        end else begin
                                            container_dmem_addr_r <=
                                                pycore_obj_field_val_addr(
                                                    call_obj_addr_r, 32'd1);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_sub_r               <= 6'd2;
                                        end
                                    end
                                end
                                6'd2: begin
                                    if (!container_dmem_pending_r) begin
                                        call_self_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <=
                                            pycore_obj_field_tag_addr(
                                                call_obj_addr_r, 32'd1);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r               <= 6'd3;
                                    end
                                end
                                6'd3: begin
                                    if (!container_dmem_pending_r) begin
                                        call_self_tag_r <= container_rd_data_r[3:0];
                                        // Free-function form requires NULL sentinel.
                                        // Method form (non-NULL) still OK for bound builtins.
                                        if (call_entry_slot_r[31:0] == PY_BI_MAX) begin
                                            if (cur_arg_r[15:0] != 16'd2) begin
                                                call_filter_trap_r <= 1'b1;
                                            end else begin
                                                container_rf_addr_r <= RF_AW'(
                                                    {2'b0, tos_r} - 9'd2);
                                                call_sub_r <= 6'd4;
                                            end
                                        end else if (call_entry_slot_r[31:0] == PY_BI_LEN) begin
                                            if (cur_arg_r[15:0] != 16'd1) begin
                                                call_filter_trap_r <= 1'b1;
                                            end else begin
                                                container_rf_addr_r <= RF_AW'(
                                                    {2'b0, tos_r} - 9'd1);
                                                call_sub_r <= 6'd6;
                                            end
                                        end else if (call_entry_slot_r[31:0] ==
                                                     PY_BI_RANGE) begin
                                            if (cur_arg_r[15:0] < 16'd1 ||
                                                cur_arg_r[15:0] > 16'd3) begin
                                                container_type_trap_r <= 1'b1;
                                            end else begin
                                                call_argcount_r <= cur_arg_r[15:0];
                                                container_rf_addr_r <= RF_AW'(
                                                    {2'b0, tos_r} -
                                                    {2'b0, cur_arg_r[6:0]});
                                                call_sub_r <= 6'd12;
                                            end
                                        end else if (call_entry_slot_r[31:0] ==
                                                     PY_BI_ORD) begin
                                            if (cur_arg_r[15:0] != 16'd1) begin
                                                call_filter_trap_r <= 1'b1;
                                            end else begin
                                                container_rf_addr_r <= RF_AW'(
                                                    {2'b0, tos_r} - 9'd1);
                                                call_sub_r <= 6'd52;
                                            end
                                        end else if (call_entry_slot_r[31:0] ==
                                                     PY_BI_CHR) begin
                                            if (cur_arg_r[15:0] != 16'd1) begin
                                                call_filter_trap_r <= 1'b1;
                                            end else begin
                                                container_rf_addr_r <= RF_AW'(
                                                    {2'b0, tos_r} - 9'd1);
                                                call_sub_r <= 6'd53;
                                            end
                                        end else if (call_entry_slot_r[31:0] ==
                                                     PY_BI_SET) begin
                                            if (cur_arg_r[15:0] > 16'd1) begin
                                                container_type_trap_r <= 1'b1;
                                            end else begin
                                                call_argcount_r <= cur_arg_r[15:0];
                                                if (cur_arg_r[15:0] == 16'd0) begin
                                                    container_src_len_r <= 32'd0;
                                                    container_count_r <= 7'd0;
                                                    call_sub_r <= 6'd27;
                                                end else begin
                                                    container_rf_addr_r <=
                                                        RF_AW'({2'b0, tos_r} -
                                                               9'd1);
                                                    call_sub_r <= 6'd24;
                                                end
                                            end
                                        end else if (EXCORE_EN &&
                                            pycore_trap_recoverable(PY_TRAP_BUILTIN_CALL)) begin
                                            // E0=builtin handle, E1=bound_self,
                                            // E2=arg0, E3=arg1 (if present)
                                            trap_marshal_pending_r     <= 1'b1;
                                            trap_marshal_code_r        <= PY_TRAP_BUILTIN_CALL;
                                            trap_marshal_entry_count_r <=
                                                (cur_arg_r[15:0] >= 16'd2) ? 3'd4 :
                                                (cur_arg_r[15:0] == 16'd1) ? 3'd3 : 3'd2;
                                            trap_marshal_entries_r[0]  <= pycore_make_entry(
                                                PY_TAG_OBJECT,
                                                {{96{1'b0}}, call_obj_addr_r});
                                            trap_marshal_entries_r[1]  <= pycore_make_entry(
                                                container_rd_data_r[3:0], call_self_val_r);
                                            // Stash argc in call_argcount; read args next.
                                            call_argcount_r <= cur_arg_r[15:0];
                                            if (cur_arg_r[15:0] == 16'd0) begin
                                                call_phase_r <= CALL_PHASE_DONE;
                                                call_sub_r   <= 6'd0;
                                            end else begin
                                                container_rf_addr_r <= RF_AW'(
                                                    {2'b0, tos_r} - {2'b0, cur_arg_r[6:0]});
                                                call_sub_r <= 6'd10;
                                            end
                                        end else begin
                                            call_filter_trap_r <= 1'b1;
                                        end
                                    end
                                end
                                // MAX arg0 - scratch in return_wb_data_r (entry-width).
                                6'd4: begin
                                    return_wb_data_r    <= rf_rs1;
                                    container_rf_addr_r <= RF_AW'({2'b0, tos_r} - 9'd1);
                                    call_sub_r          <= 6'd5;
                                end
                                6'd5: begin
                                    // arg0 in return_wb_data_r, arg1 in rf_rs1
                                    if ((pycore_get_tag(return_wb_data_r) != PY_TAG_INT &&
                                         pycore_get_tag(return_wb_data_r) != PY_TAG_BOOL) ||
                                        (cont_rf_rs1_tag != PY_TAG_INT &&
                                         cont_rf_rs1_tag != PY_TAG_BOOL)) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        begin
                                            logic signed [127:0] a, b, m;
                                            a = $signed(pycore_get_val(return_wb_data_r));
                                            b = $signed(cont_rf_rs1_val);
                                            m = (a > b) ? a : b;
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(
                                                {2'b0, tos_r} - 9'd4);
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_INT, m);
                                            tos_r <= RF_AW'({2'b0, tos_r} - 9'd3);
                                            fetch_skip_r <= 1'b1;
                                            call_phase_r <= CALL_PHASE_DONE;
                                            call_sub_r   <= 6'd0;
                                        end
                                    end
                                end
                                // LEN arg0
                                6'd6: begin
                                    if (pycore_is_list(
                                            cont_rf_rs1_tag, cont_rf_rs1_val)) begin
                                        container_dmem_addr_r    <= cont_rf_rs1_val[31:0];
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r               <= 6'd7;
                                    end else if (cont_rf_rs1_tag == PY_TAG_TUPLE) begin
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(
                                            {2'b0, tos_r} - 9'd3);
                                        container_wb_data_r <= pycore_make_entry(
                                            PY_TAG_INT,
                                            {{64{1'b0}},
                                             pycore_tuple_size(cont_rf_rs1_val)});
                                        tos_r <= RF_AW'({2'b0, tos_r} - 9'd2);
                                        fetch_skip_r <= 1'b1;
                                        call_phase_r <= CALL_PHASE_DONE;
                                        call_sub_r   <= 6'd0;
                                    end else if (pycore_is_dict(
                                                         cont_rf_rs1_tag,
                                                         cont_rf_rs1_val) ||
                                                 pycore_is_set(
                                                         cont_rf_rs1_tag,
                                                         cont_rf_rs1_val)) begin
                                        container_dmem_addr_r    <= cont_rf_rs1_val[31:0];
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r               <= 6'd8;
                                    end else if (cont_rf_rs1_tag == PY_TAG_SHORT_STR) begin
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(
                                            {2'b0, tos_r} - 9'd3);
                                        container_wb_data_r <= pycore_make_entry(
                                            PY_TAG_INT,
                                            {{120{1'b0}},
                                             pycore_short_str_size(cont_rf_rs1_val)});
                                        tos_r <= RF_AW'({2'b0, tos_r} - 9'd2);
                                        fetch_skip_r <= 1'b1;
                                        call_phase_r <= CALL_PHASE_DONE;
                                        call_sub_r   <= 6'd0;
                                    end else if (cont_rf_rs1_tag == PY_TAG_LONG_STR) begin
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(
                                            {2'b0, tos_r} - 9'd3);
                                        container_wb_data_r <= pycore_make_entry(
                                            PY_TAG_INT,
                                            {{64{1'b0}},
                                             pycore_long_str_size(cont_rf_rs1_val)});
                                        tos_r <= RF_AW'({2'b0, tos_r} - 9'd2);
                                        fetch_skip_r <= 1'b1;
                                        call_phase_r <= CALL_PHASE_DONE;
                                        call_sub_r   <= 6'd0;
                                    end else if (cont_rf_rs1_tag == PY_TAG_RANGE) begin
                                        if (pycore_range_is_tuple_mode(
                                                cont_rf_rs1_val)) begin
                                            // Tuple-mode RANGE length needs heap tuple
                                            // element reads; follow-up milestone.
                                            container_type_trap_r <= 1'b1;
                                        end else if (cont_rf_rs1_val[31:0] == 32'd0) begin
                                            // step==0 is rejected by BI_RANGE; defensive.
                                            container_type_trap_r <= 1'b1;
                                        end else begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(
                                                {2'b0, tos_r} - 9'd3);
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_INT,
                                                {{64{1'b0}},
                                                 pycore_range_inline_len(
                                                     cont_rf_rs1_val)});
                                            tos_r <= RF_AW'(
                                                {2'b0, tos_r} - 9'd2);
                                            fetch_skip_r <= 1'b1;
                                            call_phase_r <= CALL_PHASE_DONE;
                                            call_sub_r   <= 6'd0;
                                        end
                                    end else if (cont_rf_rs1_tag == PY_TAG_OBJECT) begin
                                        call_inst_addr_r <= cont_rf_rs1_val[31:0];
                                        container_dmem_addr_r    <= cont_rf_rs1_val[31:0];
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r               <= 6'd40;
                                    end else begin
                                        container_type_trap_r <= 1'b1;
                                    end
                                end
                                6'd7: begin
                                    if (!container_dmem_pending_r) begin
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(
                                            {2'b0, tos_r} - 9'd3);
                                        container_wb_data_r <= pycore_make_entry(
                                            PY_TAG_INT,
                                            {{64{1'b0}}, cont_hdr_len});
                                        tos_r <= RF_AW'({2'b0, tos_r} - 9'd2);
                                        fetch_skip_r <= 1'b1;
                                        call_phase_r <= CALL_PHASE_DONE;
                                        call_sub_r   <= 6'd0;
                                    end
                                end
                                6'd8: begin
                                    if (!container_dmem_pending_r) begin
                                        // dict/set header: used in low 64 of first word
                                        // via cont_dict_hdr_used
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(
                                            {2'b0, tos_r} - 9'd3);
                                        container_wb_data_r <= pycore_make_entry(
                                            PY_TAG_INT,
                                            {{64{1'b0}}, cont_dict_hdr_used});
                                        tos_r <= RF_AW'({2'b0, tos_r} - 9'd2);
                                        fetch_skip_r <= 1'b1;
                                        call_phase_r <= CALL_PHASE_DONE;
                                        call_sub_r   <= 6'd0;
                                    end
                                end
                                // Marshal remaining CALL args into trap entries.
                                6'd10: begin
                                    trap_marshal_entries_r[2] <= rf_rs1;
                                    if (call_argcount_r >= 16'd2) begin
                                        container_rf_addr_r <= RF_AW'(
                                            {2'b0, tos_r} - 9'd1);
                                        call_sub_r <= 6'd11;
                                    end else begin
                                        call_phase_r <= CALL_PHASE_DONE;
                                        call_sub_r   <= 6'd0;
                                    end
                                end
                                6'd11: begin
                                    trap_marshal_entries_r[3] <= rf_rs1;
                                    call_phase_r <= CALL_PHASE_DONE;
                                    call_sub_r   <= 6'd0;
                                end
                                // RANGE arg0. Normalize range(stop) immediately;
                                // otherwise retain start and read stop.
                                6'd12: begin
                                    if (cont_rf_rs1_tag != PY_TAG_INT &&
                                        cont_rf_rs1_tag != PY_TAG_BOOL) begin
                                        container_type_trap_r <= 1'b1;
                                    end else if (call_argcount_r == 16'd1) begin
                                        call_range_start_r <= 128'b0;
                                        call_range_stop_r  <= cont_rf_rs1_val;
                                        call_range_step_r  <= 128'd1;
                                        call_sub_r         <= 6'd15;
                                    end else begin
                                        call_range_start_r <= cont_rf_rs1_val;
                                        container_rf_addr_r <= RF_AW'(
                                            {2'b0, tos_r} -
                                            {2'b0, call_argcount_r[6:0]} + 9'd1);
                                        call_sub_r <= 6'd13;
                                    end
                                end
                                // RANGE arg1 (stop).
                                6'd13: begin
                                    if (cont_rf_rs1_tag != PY_TAG_INT &&
                                        cont_rf_rs1_tag != PY_TAG_BOOL) begin
                                        container_type_trap_r <= 1'b1;
                                    end else if (call_argcount_r == 16'd2) begin
                                        call_range_stop_r <= cont_rf_rs1_val;
                                        call_range_step_r <= 128'd1;
                                        call_sub_r        <= 6'd15;
                                    end else begin
                                        call_range_stop_r <= cont_rf_rs1_val;
                                        container_rf_addr_r <= RF_AW'(
                                            {2'b0, tos_r} - 9'd1);
                                        call_sub_r <= 6'd14;
                                    end
                                end
                                // RANGE arg2 (step).
                                6'd14: begin
                                    if (cont_rf_rs1_tag != PY_TAG_INT &&
                                        cont_rf_rs1_tag != PY_TAG_BOOL) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        call_range_step_r <= cont_rf_rs1_val;
                                        call_sub_r        <= 6'd15;
                                    end
                                end
                                // Emit compact RANGE directly; extended
                                // arguments use a heap 3-tuple payload.
                                6'd15: begin
                                    if (call_range_step_r == 128'b0) begin
                                        container_type_trap_r <= 1'b1;
                                    end else if (
                                        call_range_start_r[127:31] ==
                                            {97{call_range_start_r[31]}} &&
                                        call_range_stop_r[127:31] ==
                                            {97{call_range_stop_r[31]}} &&
                                        call_range_step_r[127:31] ==
                                            {97{call_range_step_r[31]}}) begin
                                        container_wb_we_r <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(
                                            {2'b0, tos_r} -
                                            {2'b0, call_argcount_r[6:0]} - 9'd2);
                                        container_wb_data_r <= pycore_make_entry(
                                            PY_TAG_RANGE,
                                            pycore_range_inline_value(
                                                call_range_start_r[31:0],
                                                call_range_stop_r[31:0],
                                                call_range_step_r[31:0]));
                                        tos_r <= RF_AW'(
                                            {2'b0, tos_r} -
                                            {2'b0, call_argcount_r[6:0]} - 9'd1);
                                        fetch_skip_r <= 1'b1;
                                        call_phase_r <= CALL_PHASE_DONE;
                                        call_sub_r <= 6'd0;
                                    end else if ((heap_ptr_r + 32'd96) >
                                                 PYCORE_HEAP_LIMIT) begin
                                        container_mem_fault_r <= 1'b1;
                                    end else begin
                                        container_base_r <= heap_ptr_r;
                                        heap_ptr_r <= heap_ptr_r + 32'd96;
                                        container_dmem_addr_r <= heap_ptr_r;
                                        container_dmem_we_r <= 1'b1;
                                        container_dmem_wdata_r <= call_range_start_r;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd16;
                                    end
                                end
                                6'd16: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r <= container_base_r + 32'd16;
                                        container_dmem_we_r <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, PY_TAG_INT};
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd17;
                                    end
                                end
                                6'd17: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r <= container_base_r + 32'd32;
                                        container_dmem_we_r <= 1'b1;
                                        container_dmem_wdata_r <= call_range_stop_r;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd18;
                                    end
                                end
                                6'd18: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r <= container_base_r + 32'd48;
                                        container_dmem_we_r <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, PY_TAG_INT};
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd19;
                                    end
                                end
                                6'd19: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r <= container_base_r + 32'd64;
                                        container_dmem_we_r <= 1'b1;
                                        container_dmem_wdata_r <= call_range_step_r;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd20;
                                    end
                                end
                                6'd20: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r <= container_base_r + 32'd80;
                                        container_dmem_we_r <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, PY_TAG_INT};
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd21;
                                    end
                                end
                                6'd21: begin
                                    if (!container_dmem_pending_r) begin
                                        container_wb_we_r <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(
                                            {2'b0, tos_r} -
                                            {2'b0, call_argcount_r[6:0]} - 9'd2);
                                        container_wb_data_r <= pycore_make_entry(
                                            PY_TAG_RANGE,
                                            pycore_range_tuple_value(
                                                {32'b0, container_base_r}));
                                        tos_r <= RF_AW'(
                                            {2'b0, tos_r} -
                                            {2'b0, call_argcount_r[6:0]} - 9'd1);
                                        fetch_skip_r <= 1'b1;
                                        call_phase_r <= CALL_PHASE_DONE;
                                        call_sub_r <= 6'd0;
                                    end
                                end
                                // SET arg: zero args, or one LIST/TUPLE source.
                                6'd24: begin
                                    if (pycore_is_list(
                                            cont_rf_rs1_tag,
                                            cont_rf_rs1_val)) begin
                                        container_src_buf_r <= cont_rf_rs1_val[31:0];
                                        container_dmem_addr_r <=
                                            cont_rf_rs1_val[31:0];
                                        container_dmem_we_r <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd25;
                                    end else if (cont_rf_rs1_tag ==
                                                 PY_TAG_TUPLE) begin
                                        // Latch tuple size before slicing -
                                        // some simulators reject func()[bits].
                                        begin
                                            logic [63:0] set_src_size;
                                            set_src_size =
                                                pycore_tuple_size(cont_rf_rs1_val);
                                            if (set_src_size[63:7] != 57'b0) begin
                                                container_type_trap_r <= 1'b1;
                                            end else begin
                                                container_src_buf_r <=
                                                    cont_rf_rs1_val[31:0];
                                                container_src_len_r <=
                                                    set_src_size[31:0];
                                                container_count_r <=
                                                    set_src_size[6:0];
                                                call_sub_r <= 6'd27;
                                            end
                                        end
                                    end else begin
                                        container_type_trap_r <= 1'b1;
                                    end
                                end
                                // LIST header then ob_item.
                                6'd25: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_hdr_len[63:7] != 57'b0) begin
                                            container_type_trap_r <= 1'b1;
                                        end else begin
                                            container_src_len_r <=
                                                cont_hdr_len[31:0];
                                            container_count_r <=
                                                cont_hdr_len[6:0];
                                            container_dmem_addr_r <=
                                                pycore_list_obitem_addr(
                                                    container_src_buf_r);
                                            container_dmem_we_r <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_sub_r <= 6'd26;
                                        end
                                    end
                                end
                                6'd26: begin
                                    if (!container_dmem_pending_r) begin
                                        container_src_buf_r <= cont_obitem_buf;
                                        call_sub_r <= 6'd27;
                                    end
                                end
                                // Allocate SET object + table.
                                6'd27: begin
                                    logic [31:0] set_slots;
                                    set_slots = pycore_set_min_slots(
                                        container_count_r);
                                    if ((heap_ptr_r +
                                         pycore_set_alloc_bytes(set_slots)) >
                                        PYCORE_HEAP_LIMIT) begin
                                        container_mem_fault_r <= 1'b1;
                                    end else begin
                                        container_base_r <= heap_ptr_r;
                                        container_buf_r <= heap_ptr_r + 32'd32;
                                        container_slot_count_r <= set_slots;
                                        container_used_r <= 64'd0;
                                        container_idx_r <= 7'd0;
                                        heap_ptr_r <= heap_ptr_r +
                                            pycore_set_alloc_bytes(set_slots);
                                        container_dmem_addr_r <= heap_ptr_r;
                                        container_dmem_we_r <= 1'b1;
                                        container_dmem_wdata_r <=
                                            pycore_set_header(
                                                {32'b0, set_slots}, 64'd0);
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd28;
                                    end
                                end
                                6'd28: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r <=
                                            pycore_set_table_ptr_addr(
                                                container_base_r);
                                        container_dmem_we_r <= 1'b1;
                                        container_dmem_wdata_r <=
                                            {{64{1'b0}},
                                             {32'b0, container_buf_r}};
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd29;
                                    end
                                end
                                6'd29: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_src_len_r == 32'd0) begin
                                            call_sub_r <= 6'd37;
                                        end else begin
                                            container_dmem_addr_r <=
                                                pycore_list_val_addr(
                                                    container_src_buf_r, 32'd0);
                                            container_dmem_we_r <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_sub_r <= 6'd30;
                                        end
                                    end
                                end
                                6'd30: begin
                                    if (!container_dmem_pending_r) begin
                                        container_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <=
                                            pycore_list_tag_addr(
                                                container_src_buf_r,
                                                {25'b0, container_idx_r});
                                        container_dmem_we_r <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd31;
                                    end
                                end
                                6'd31: begin
                                    if (!container_dmem_pending_r) begin
                                        if (!pycore_dict_key_tag_ok(
                                                container_rd_data_r[3:0])) begin
                                            container_type_trap_r <= 1'b1;
                                        end else begin
                                            logic [31:0] probe0;
                                            container_tag_r <=
                                                container_rd_data_r[3:0];
                                            probe0 = pycore_dict_key_hash(
                                                container_rd_data_r[3:0],
                                                container_val_r) &
                                                (container_slot_count_r - 32'd1);
                                            container_probe_r <= probe0;
                                            container_probe_n_r <= 32'd0;
                                            container_dmem_addr_r <=
                                                pycore_set_tag_addr(
                                                    container_buf_r, probe0);
                                            container_dmem_we_r <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_sub_r <= 6'd32;
                                        end
                                    end
                                end
                                6'd32: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_probe_n_r >=
                                            container_slot_count_r) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else if (container_rd_data_r[3:0] ==
                                                     PY_TAG_UNINIT) begin
                                            container_dmem_addr_r <=
                                                pycore_set_val_addr(
                                                    container_buf_r,
                                                    container_probe_r);
                                            container_dmem_we_r <= 1'b1;
                                            container_dmem_wdata_r <=
                                                container_val_r;
                                            container_dmem_pending_r <= 1'b1;
                                            call_sub_r <= 6'd34;
                                        end else begin
                                            container_probe_tag_r <=
                                                container_rd_data_r[3:0];
                                            container_dmem_addr_r <=
                                                pycore_set_val_addr(
                                                    container_buf_r,
                                                    container_probe_r);
                                            container_dmem_we_r <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_sub_r <= 6'd33;
                                        end
                                    end
                                end
                                6'd33: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_dict_key_match) begin
                                            call_sub_r <= 6'd36;
                                        end else begin
                                            container_probe_r <=
                                                cont_probe_next;
                                            container_probe_n_r <=
                                                container_probe_n_r + 32'd1;
                                            container_dmem_addr_r <=
                                                pycore_set_tag_addr(
                                                    container_buf_r,
                                                    cont_probe_next);
                                            container_dmem_we_r <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_sub_r <= 6'd32;
                                        end
                                    end
                                end
                                6'd34: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r <=
                                            pycore_set_tag_addr(
                                                container_buf_r,
                                                container_probe_r);
                                        container_dmem_we_r <= 1'b1;
                                        container_dmem_wdata_r <=
                                            {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd35;
                                    end
                                end
                                6'd35: begin
                                    if (!container_dmem_pending_r) begin
                                        container_used_r <=
                                            container_used_r + 64'd1;
                                        call_sub_r <= 6'd36;
                                    end
                                end
                                6'd36: begin
                                    if (container_idx_r + 7'd1 <
                                        container_count_r) begin
                                        container_idx_r <=
                                            container_idx_r + 7'd1;
                                        container_dmem_addr_r <=
                                            pycore_list_val_addr(
                                                container_src_buf_r,
                                                {25'b0, container_idx_r} +
                                                32'd1);
                                        container_dmem_we_r <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd30;
                                    end else begin
                                        container_dmem_addr_r <=
                                            container_base_r;
                                        container_dmem_we_r <= 1'b1;
                                        container_dmem_wdata_r <=
                                            pycore_set_header(
                                                {32'b0,
                                                 container_slot_count_r},
                                                container_used_r);
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd37;
                                    end
                                end
                                6'd37: begin
                                    if (!container_dmem_pending_r) begin
                                        container_wb_we_r <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(
                                            {2'b0, tos_r} -
                                            {2'b0,
                                             call_argcount_r[6:0]} - 9'd2);
                                        container_wb_data_r <= pycore_make_mut(
                                            PY_MUT_SET,
                                            {32'b0, container_base_r}, 1'b0);
                                        tos_r <= RF_AW'(
                                            {2'b0, tos_r} -
                                            {2'b0,
                                             call_argcount_r[6:0]} - 9'd1);
                                        fetch_skip_r <= 1'b1;
                                        call_phase_r <= CALL_PHASE_DONE;
                                        call_sub_r <= 6'd0;
                                    end
                                end
                                // LEN INSTANCE path: read object head.
                                6'd40: begin
                                    if (!container_dmem_pending_r) begin
                                        begin
                                            logic [63:0] len_type_addr;
                                            len_type_addr =
                                                pycore_ob_type(container_rd_data_r);
                                            if (pycore_ob_kind(container_rd_data_r) !=
                                                    PY_OBK_INSTANCE ||
                                                len_type_addr[31:0] == 32'd0) begin
                                                container_type_trap_r <= 1'b1;
                                            end else begin
                                                container_src_buf_r <=
                                                    len_type_addr[31:0];
                                                container_dmem_addr_r <=
                                                    len_type_addr[31:0];
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                call_sub_r <= 6'd41;
                                            end
                                        end
                                    end
                                end
                                // LEN INSTANCE path: require TYPE head.
                                6'd41: begin
                                    if (!container_dmem_pending_r) begin
                                        if (pycore_ob_kind(container_rd_data_r) !=
                                                PY_OBK_TYPE) begin
                                            container_type_trap_r <= 1'b1;
                                        end else begin
                                            container_dmem_addr_r <=
                                                pycore_obj_field_val_addr(
                                                    container_src_buf_r, 32'd0);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_sub_r <= 6'd42;
                                        end
                                    end
                                end
                                // LEN INSTANCE path: latch tp_dict val; read tag.
                                6'd42: begin
                                    if (!container_dmem_pending_r) begin
                                        container_base_r <= container_rd_data_r[31:0];
                                        container_dmem_addr_r <=
                                            pycore_obj_field_tag_addr(
                                                container_src_buf_r, 32'd0);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd43;
                                    end
                                end
                                // LEN INSTANCE path: require tp_dict; read header.
                                6'd43: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_rd_data_r[3:0] !=
                                                PY_TAG_MUT_COLLEC) begin
                                            container_type_trap_r <= 1'b1;
                                        end else begin
                                            container_dmem_addr_r    <= container_base_r;
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_sub_r <= 6'd44;
                                        end
                                    end
                                end
                                // LEN INSTANCE path: latch slots; read table_ptr.
                                6'd44: begin
                                    if (!container_dmem_pending_r) begin
                                        container_slot_count_r <=
                                            cont_dict_hdr_slots[31:0];
                                        container_dmem_addr_r <=
                                            pycore_dict_table_ptr_addr(
                                                container_base_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd45;
                                    end
                                end
                                // LEN INSTANCE path: start __len__ probe.
                                6'd45: begin
                                    if (!container_dmem_pending_r) begin
                                        container_buf_r <= cont_dict_table_ptr;
                                        container_tag_r <= PY_TAG_SHORT_STR;
                                        container_val_r <= CALL_LEN_NAME_VAL;
                                        if ((container_slot_count_r == 32'd0) ||
                                            (cont_dict_table_ptr == 32'd0)) begin
                                            container_attr_error_r <= 1'b1;
                                        end else begin
                                            begin
                                                logic [31:0] probe0;
                                                probe0 = pycore_dict_key_hash(
                                                    PY_TAG_SHORT_STR,
                                                    CALL_LEN_NAME_VAL)
                                                    & (container_slot_count_r - 32'd1);
                                                container_probe_r   <= probe0;
                                                container_probe_n_r <= 32'd0;
                                                container_dmem_addr_r <=
                                                    pycore_dict_ktag_addr(
                                                        cont_dict_table_ptr, probe0);
                                            end
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_sub_r <= 6'd46;
                                        end
                                    end
                                end
                                // LEN INSTANCE path: probe ktag.
                                6'd46: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_probe_n_r >=
                                                container_slot_count_r) begin
                                            container_attr_error_r <= 1'b1;
                                        end else begin
                                            container_probe_n_r <=
                                                container_probe_n_r + 32'd1;
                                            if (pycore_dict_slot_empty(
                                                    container_rd_data_r)) begin
                                                container_attr_error_r <= 1'b1;
                                            end else if (pycore_dict_tombstone(
                                                            container_rd_data_r[3:0])) begin
                                                if (container_probe_n_r + 32'd1 >=
                                                        container_slot_count_r) begin
                                                    container_attr_error_r <= 1'b1;
                                                end else begin
                                                    container_probe_r <= cont_probe_next;
                                                    container_dmem_addr_r <=
                                                        pycore_dict_ktag_addr(
                                                            container_buf_r,
                                                            cont_probe_next);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                end
                                            end else begin
                                                container_probe_tag_r <=
                                                    container_rd_data_r[3:0];
                                                container_dmem_addr_r <=
                                                    pycore_dict_kval_addr(
                                                        container_buf_r,
                                                        container_probe_r);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                call_sub_r <= 6'd47;
                                            end
                                        end
                                    end
                                end
                                // LEN INSTANCE path: compare key value.
                                6'd47: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_dict_key_match) begin
                                            container_dmem_addr_r <=
                                                pycore_dict_vval_addr(
                                                    container_buf_r,
                                                    container_probe_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_sub_r <= 6'd48;
                                        end else if (container_probe_n_r >=
                                                     container_slot_count_r) begin
                                            container_attr_error_r <= 1'b1;
                                        end else begin
                                            container_probe_r <= cont_probe_next;
                                            container_dmem_addr_r <=
                                                pycore_dict_ktag_addr(
                                                    container_buf_r, cont_probe_next);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_sub_r <= 6'd46;
                                        end
                                    end
                                end
                                // LEN INSTANCE path: __len__ value.
                                6'd48: begin
                                    if (!container_dmem_pending_r) begin
                                        call_code_addr_r <= container_rd_data_r[31:0];
                                        container_dmem_addr_r <=
                                            pycore_dict_vtag_addr(
                                                container_buf_r, container_probe_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd49;
                                    end
                                end
                                // LEN INSTANCE path: require CODE_OBJECT; write callable.
                                6'd49: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_rd_data_r[3:0] !=
                                                PY_TAG_CODE_OBJECT) begin
                                            call_filter_trap_r <= 1'b1;
                                        end else begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(
                                                {2'b0, tos_r} - 9'd3);
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_CODE_OBJECT,
                                                {{96{1'b0}}, call_code_addr_r});
                                            call_argcount_r   <= 16'd1;
                                            call_new_locals_r <= RF_AW'(
                                                {2'b0, tos_r} - 9'd2);
                                            call_sub_r <= 6'd50;
                                        end
                                    end
                                end
                                // LEN INSTANCE path: write self into method slot.
                                6'd50: begin
                                    container_wb_we_r   <= 1'b1;
                                    container_wb_addr_r <= RF_AW'(
                                        {2'b0, tos_r} - 9'd2);
                                    container_wb_data_r <= pycore_make_entry(
                                        PY_TAG_OBJECT,
                                        {{96{1'b0}}, call_inst_addr_r});
                                    call_sub_r <= 6'd51;
                                end
                                // LEN INSTANCE path: join code-object field reads.
                                6'd51: begin
                                    container_dmem_addr_r    <=
                                        pycore_code_field_val_addr(
                                            call_code_addr_r,
                                            PYCORE_CODE_FIELD_ENTRY_SLOT);
                                    container_dmem_we_r      <= 1'b0;
                                    container_dmem_pending_r <= 1'b1;
                                    call_sub_r               <= 6'd0;
                                    call_phase_r             <= 4'd3;
                                end
                                // ORD arg0: one-character STR → INT code point.
                                // A one-character string is always SHORT_STR
                                // (every string of <= 15 bytes is), so a
                                // LONG_STR is by construction longer than one
                                // character and is a length error here.  Bytes
                                // are inline in the handle, so this needs no
                                // string_mem access and completes in one cycle.
                                6'd52: begin
                                    begin
                                        logic [31:0] ord_bytes;
                                        logic [2:0]  ord_width;
                                        logic        ord_conts_ok;
                                        ord_bytes = {
                                            pycore_short_str_byte(
                                                cont_rf_rs1_val, 3),
                                            pycore_short_str_byte(
                                                cont_rf_rs1_val, 2),
                                            pycore_short_str_byte(
                                                cont_rf_rs1_val, 1),
                                            pycore_short_str_byte(
                                                cont_rf_rs1_val, 0)};
                                        ord_width = pycore_utf8_char_width(
                                            ord_bytes[7:0]);
                                        ord_conts_ok =
                                            ((ord_width < 3'd2) ||
                                             pycore_utf8_cont_valid(
                                                 ord_bytes[15:8])) &&
                                            ((ord_width < 3'd3) ||
                                             pycore_utf8_cont_valid(
                                                 ord_bytes[23:16])) &&
                                            ((ord_width < 3'd4) ||
                                             pycore_utf8_cont_valid(
                                                 ord_bytes[31:24]));
                                        if ((cont_rf_rs1_tag !=
                                                 PY_TAG_SHORT_STR) ||
                                            (ord_width == 3'd0) ||
                                            !ord_conts_ok ||
                                            ({1'b0, ord_width} !=
                                             pycore_short_str_size(
                                                 cont_rf_rs1_val))) begin
                                            // Not a string, malformed UTF-8, or
                                            // not exactly one character.
                                            container_type_trap_r <= 1'b1;
                                        end else begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(
                                                {2'b0, tos_r} - 9'd3);
                                            container_wb_data_r <=
                                                pycore_make_entry(
                                                    PY_TAG_INT,
                                                    {{96{1'b0}},
                                                     pycore_utf8_decode(
                                                         ord_width,
                                                         ord_bytes)});
                                            tos_r <= RF_AW'(
                                                {2'b0, tos_r} - 9'd2);
                                            fetch_skip_r <= 1'b1;
                                            call_phase_r <= CALL_PHASE_DONE;
                                            call_sub_r   <= 6'd0;
                                        end
                                    end
                                end
                                // CHR arg0: INT code point → one-character
                                // SHORT_STR.  Also one cycle: the 1-4 encoded
                                // bytes live inline in the result handle.
                                6'd53: begin
                                    begin
                                        logic [31:0] chr_cp;
                                        logic [2:0]  chr_width;
                                        chr_cp    = cont_rf_rs1_val[31:0];
                                        chr_width = pycore_utf8_encode_width(
                                            chr_cp);
                                        if (((cont_rf_rs1_tag != PY_TAG_INT) &&
                                             (cont_rf_rs1_tag !=
                                              PY_TAG_BOOL)) ||
                                            (cont_rf_rs1_val[127:32] !=
                                             96'b0) ||
                                            (chr_width == 3'd0) ||
                                            pycore_utf8_is_surrogate(
                                                chr_cp)) begin
                                            // Non-int, negative (high bits
                                            // set), > U+10FFFF, or a surrogate.
                                            container_type_trap_r <= 1'b1;
                                        end else begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(
                                                {2'b0, tos_r} - 9'd3);
                                            container_wb_data_r <=
                                                pycore_make_short_str_entry(
                                                    {1'b0, chr_width},
                                                    pycore_utf8_encode_payload(
                                                        chr_cp, chr_width));
                                            tos_r <= RF_AW'(
                                                {2'b0, tos_r} - 9'd2);
                                            fetch_skip_r <= 1'b1;
                                            call_phase_r <= CALL_PHASE_DONE;
                                            call_sub_r   <= 6'd0;
                                        end
                                    end
                                end
                                default: call_filter_trap_r <= 1'b1;
                            endcase
                        end

                        // --------------------------------------------------
                        // Phase 12: TYPE instantiation + __init__ (own tp_dict)
                        // --------------------------------------------------
                        4'd12: begin
                            unique case (call_sub_r)
                                // 0: OOM + allocate dict (4 slots) + INSTANCE.
                                6'd0: begin
                                    if ((heap_ptr_r + CALL_TYPE_ALLOC_BYTES) >
                                            PYCORE_HEAP_LIMIT) begin
                                        container_mem_fault_r <= 1'b1;
                                    end else begin
                                        container_base_r   <= heap_ptr_r;
                                        container_order_ptr_r <= heap_ptr_r + 32'd48;
                                        container_buf_r    <= heap_ptr_r + 32'd48 +
                                            (CALL_EMPTY_DICT_SLOTS << 5);
                                        call_inst_addr_r   <= heap_ptr_r
                                            + pycore_dict_alloc_bytes(
                                                CALL_EMPTY_DICT_SLOTS);
                                        container_slot_count_r <= CALL_EMPTY_DICT_SLOTS;
                                        heap_ptr_r <= heap_ptr_r + CALL_TYPE_ALLOC_BYTES;
                                        container_dmem_addr_r  <= heap_ptr_r;
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= pycore_dict_header(
                                            {32'b0, CALL_EMPTY_DICT_SLOTS}, 64'd0);
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd1;
                                    end
                                end
                                // 1: dict metadata
                                6'd1: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r <=
                                            pycore_dict_meta_addr(
                                                container_base_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= 128'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd21;
                                    end
                                end
                                // 21: packed order/table pointers.
                                6'd21: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r <=
                                            pycore_dict_table_ptr_addr(
                                                container_base_r);
                                        container_dmem_we_r <= 1'b1;
                                        container_dmem_wdata_r <= {
                                            32'b0, container_order_ptr_r,
                                            32'b0, container_buf_r
                                        };
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd2;
                                    end
                                end
                                // 2: instance ob_head (ob_type = type addr)
                                6'd2: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= call_inst_addr_r;
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= pycore_pack_ob_head(
                                            PY_OBK_INSTANCE, 32'd0,
                                            {32'b0, call_obj_addr_r});
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd3;
                                    end
                                end
                                // 3: instance self-tag
                                6'd3: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <=
                                            call_inst_addr_r + 32'd16;
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <=
                                            {124'b0, PY_TAG_OBJECT};
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd4;
                                    end
                                end
                                // 4: field0 __dict__ val
                                6'd4: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r <=
                                            pycore_obj_field_val_addr(
                                                call_inst_addr_r, 32'd0);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <=
                                            pycore_mut_value(
                                                PY_MUT_DICT,
                                                {32'b0, container_base_r}, 1'b0);
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd5;
                                    end
                                end
                                // 5: field0 __dict__ tag
                                6'd5: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r <=
                                            pycore_obj_field_tag_addr(
                                                call_inst_addr_r, 32'd0);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <=
                                            {124'b0, PY_TAG_MUT_COLLEC};
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd6;
                                    end
                                end
                                // 6: read type.tp_dict val
                                6'd6: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r <=
                                            pycore_obj_field_val_addr(
                                                call_obj_addr_r, 32'd0);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd7;
                                    end
                                end
                                // 7: latch tp_dict addr; read tag
                                6'd7: begin
                                    if (!container_dmem_pending_r) begin
                                        container_base_r <= container_rd_data_r[31:0];
                                        container_dmem_addr_r <=
                                            pycore_obj_field_tag_addr(
                                                call_obj_addr_r, 32'd0);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd8;
                                    end
                                end
                                // 8: require DICT; read header
                                6'd8: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_rd_data_r[3:0] !=
                                                PY_TAG_MUT_COLLEC) begin
                                            call_filter_trap_r <= 1'b1;
                                        end else begin
                                            container_dmem_addr_r    <= container_base_r;
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_sub_r <= 6'd9;
                                        end
                                    end
                                end
                                // 9: latch slots; read table_ptr
                                6'd9: begin
                                    if (!container_dmem_pending_r) begin
                                        container_slot_count_r <=
                                            cont_dict_hdr_slots[31:0];
                                        container_dmem_addr_r <=
                                            pycore_dict_table_ptr_addr(
                                                container_base_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd10;
                                    end
                                end
                                // 10: start __init__ probe (own tp_dict only)
                                6'd10: begin
                                    if (!container_dmem_pending_r) begin
                                        container_buf_r <= cont_dict_table_ptr;
                                        container_tag_r <= PY_TAG_SHORT_STR;
                                        container_val_r <= CALL_INIT_NAME_VAL;
                                        if ((container_slot_count_r == 32'd0) ||
                                            (cont_dict_table_ptr == 32'd0)) begin
                                            // No __init__: push instance, done.
                                            call_sub_r <= 6'd20;
                                        end else begin
                                            begin
                                                logic [31:0] probe0;
                                                probe0 = pycore_dict_key_hash(
                                                    PY_TAG_SHORT_STR,
                                                    CALL_INIT_NAME_VAL)
                                                    & (container_slot_count_r - 32'd1);
                                                container_probe_r   <= probe0;
                                                container_probe_n_r <= 32'd0;
                                                container_dmem_addr_r <=
                                                    pycore_dict_ktag_addr(
                                                        cont_dict_table_ptr, probe0);
                                            end
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_sub_r <= 6'd11;
                                        end
                                    end
                                end
                                // 11: probe ktag
                                6'd11: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_probe_n_r >=
                                                container_slot_count_r) begin
                                            call_sub_r <= 6'd20; // miss
                                        end else begin
                                            container_probe_n_r <=
                                                container_probe_n_r + 32'd1;
                                            if (pycore_dict_slot_empty(
                                                    container_rd_data_r)) begin
                                                call_sub_r <= 6'd20;
                                            end else if (pycore_dict_tombstone(
                                                            container_rd_data_r[3:0])) begin
                                                if (container_probe_n_r + 32'd1 >=
                                                        container_slot_count_r) begin
                                                    call_sub_r <= 6'd20;
                                                end else begin
                                                    container_probe_r <= cont_probe_next;
                                                    container_dmem_addr_r <=
                                                        pycore_dict_ktag_addr(
                                                            container_buf_r,
                                                            cont_probe_next);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                end
                                            end else begin
                                                container_probe_tag_r <=
                                                    container_rd_data_r[3:0];
                                                container_dmem_addr_r <=
                                                    pycore_dict_kval_addr(
                                                        container_buf_r,
                                                        container_probe_r);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                call_sub_r <= 6'd12;
                                            end
                                        end
                                    end
                                end
                                // 12: rich_eq on key val
                                6'd12: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_dict_key_match) begin
                                            container_dmem_addr_r <=
                                                pycore_dict_vval_addr(
                                                    container_buf_r,
                                                    container_probe_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_sub_r <= 6'd13;
                                        end else if (container_probe_n_r >=
                                                     container_slot_count_r) begin
                                            call_sub_r <= 6'd20;
                                        end else begin
                                            container_probe_r <= cont_probe_next;
                                            container_dmem_addr_r <=
                                                pycore_dict_ktag_addr(
                                                    container_buf_r, cont_probe_next);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_sub_r <= 6'd11;
                                        end
                                    end
                                end
                                // 13: __init__ value
                                6'd13: begin
                                    if (!container_dmem_pending_r) begin
                                        call_code_addr_r <= container_rd_data_r[31:0];
                                        container_dmem_addr_r <=
                                            pycore_dict_vtag_addr(
                                                container_buf_r, container_probe_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd14;
                                    end
                                end
                                // 14: require CODE_OBJECT; install method form
                                6'd14: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_rd_data_r[3:0] !=
                                                PY_TAG_CODE_OBJECT) begin
                                            call_filter_trap_r <= 1'b1;
                                        end else begin
                                            // self = instance at sentinel slot
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(
                                                {2'b0, tos_r}
                                                - {2'b0, cur_arg_r[6:0]} - 9'd1);
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_OBJECT,
                                                {{96{1'b0}}, call_inst_addr_r});
                                            call_argcount_r   <=
                                                cur_arg_r[15:0] + 16'd1;
                                            call_new_locals_r <= RF_AW'(
                                                {2'b0, tos_r}
                                                - {2'b0, cur_arg_r[6:0]} - 9'd1);
                                            call_ret_mode_r   <= 1'b1;
                                            call_saved_inst_r <=
                                                {32'b0, call_inst_addr_r};
                                            call_sub_r <= 6'd15;
                                        end
                                    end
                                end
                                // 15: join field-read path at phase 3
                                6'd15: begin
                                    container_dmem_addr_r    <=
                                        pycore_code_field_val_addr(
                                            call_code_addr_r,
                                            PYCORE_CODE_FIELD_ENTRY_SLOT);
                                    container_dmem_we_r      <= 1'b0;
                                    container_dmem_pending_r <= 1'b1;
                                    call_sub_r               <= 6'd0;
                                    call_phase_r             <= 4'd3;
                                end
                                // 20: no __init__ - pop argc+2, push instance
                                6'd20: begin
                                    container_wb_we_r   <= 1'b1;
                                    container_wb_addr_r <= call_tos_base_r;
                                    container_wb_data_r <= pycore_make_entry(
                                        PY_TAG_OBJECT,
                                        {{96{1'b0}}, call_inst_addr_r});
                                    tos_r         <= call_tos_base_r + RF_AW'(1);
                                    fetch_skip_r  <= 1'b1;
                                    call_phase_r  <= CALL_PHASE_DONE;
                                end
                                default: ;
                            endcase
                        end

                        // --------------------------------------------------
                        // Phase 14: co_defaults arity + fill (POS) or KW binder
                        // --------------------------------------------------
                        4'd14: begin
                            if (!container_dmem_pending_r) begin
                                unique case (call_sub_r)
                                    6'd0: begin
                                        call_defaults_r     <= container_rd_data_r;
                                        call_defaults_len_r <=
                                            container_rd_data_r[79:64];
                                        begin
                                            logic [15:0] def_len;
                                            logic [15:0] meta_ac;
                                            logic [15:0] min_ac;
                                            logic [15:0] local_slots;
                                            def_len = container_rd_data_r[79:64];
                                            meta_ac = call_meta_argc_r;
                                            local_slots = meta_ac +
                                                (call_varargs_r ? 16'd1 : 16'd0) +
                                                (call_varkw_r ? 16'd1 : 16'd0);
                                            if (def_len > meta_ac) begin
                                                call_filter_trap_r <= 1'b1;
                                            end else begin
                                                min_ac = meta_ac - def_len;
                                                call_min_argc_r <= min_ac;
                                                if ((call_argcount_r < min_ac) ||
                                                    (!call_varargs_r &&
                                                     (call_argcount_r > meta_ac))) begin
                                                    call_filter_trap_r <= 1'b1;
                                                end else if (local_slots > 16'd32) begin
                                                    call_filter_trap_r <= 1'b1;
                                                end else if ((9'(call_new_locals_r)
                                                              + 9'(call_nlocals_r))
                                                             > 9'(STACK_TOP_MAX)) begin
                                                    call_filter_trap_r <= 1'b1;
                                                end else if (call_argcount_r <
                                                             meta_ac) begin
                                                    container_idx_r <=
                                                        call_argcount_r[6:0];
                                                    call_sub_r <= 6'd1;
                                                end else if (call_varargs_r) begin
                                                    call_after_varargs_sub_r <= 6'd0;
                                                    call_varargs_to_frame_r  <= 1'b1;
                                                    call_sub_r <= 6'd20;
                                                end else begin
                                                    call_phase_r <= 4'd7;
                                                end
                                            end
                                        end
                                    end
                                    // Read defaults[idx - min_argc] val
                                    6'd1: begin
                                        begin
                                            logic [31:0] def_i;
                                            def_i = {16'b0, container_idx_r}
                                                    - {16'b0, call_min_argc_r};
                                            container_dmem_addr_r <=
                                                pycore_tuple_val_addr(
                                                    call_defaults_r[31:0], def_i);
                                        end
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd2;
                                    end
                                    6'd2: begin
                                        container_val_r <= container_rd_data_r;
                                        begin
                                            logic [31:0] def_i;
                                            def_i = {16'b0, container_idx_r}
                                                    - {16'b0, call_min_argc_r};
                                            container_dmem_addr_r <=
                                                pycore_tuple_tag_addr(
                                                    call_defaults_r[31:0], def_i);
                                        end
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd3;
                                    end
                                    6'd3: begin
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <=
                                            call_new_locals_r + container_idx_r[RF_AW-1:0];
                                        container_wb_data_r <= pycore_make_entry(
                                            container_rd_data_r[3:0], container_val_r);
                                        if (({9'b0, container_idx_r} + 9'd1) >=
                                                {2'b0, call_meta_argc_r[6:0]}) begin
                                            if (call_varargs_r) begin
                                                call_argcount_r <= call_meta_argc_r;
                                                call_after_varargs_sub_r <= 6'd0;
                                                call_varargs_to_frame_r  <= 1'b1;
                                                call_sub_r <= 6'd20;
                                            end else begin
                                                // All positional params now
                                                // filled (args + defaults).
                                                // Bump argc so phase-7 ranged
                                                // UNINIT clear starts after
                                                // them instead of wiping them.
                                                call_argcount_r <= call_meta_argc_r;
                                                call_sub_r   <= 6'd0;
                                                call_phase_r <= 4'd7;
                                            end
                                        end else begin
                                            container_idx_r <= container_idx_r + 7'd1;
                                            call_sub_r <= 6'd1;
                                        end
                                    end

                                    // ------------------------------------------
                                    // CO_VARARGS tuple pack (subs 20-24).
                                    // Excess positionals live at locals[argcount..)
                                    // until this copy completes.  CPython 3.14 in
                                    // this toolchain orders varnames as positional,
                                    // keyword-only, then *args, so the tuple local
                                    // is argcount + kwonlyargcount.
                                    // ------------------------------------------
                                    6'd20: begin
                                        if (!call_varargs_r) begin
                                            if (call_varargs_to_frame_r) begin
                                                call_phase_r <= 4'd7;
                                            end else begin
                                                call_sub_r <= call_after_varargs_sub_r;
                                            end
                                        end else begin
                                            begin
                                                logic [15:0] extra;
                                                if (call_argcount_r <
                                                        call_meta_argc_r)
                                                    extra = 16'd0;
                                                else
                                                    extra = call_argcount_r -
                                                            call_meta_argc_r;
                                                if (extra[15:7] != 9'b0) begin
                                                    call_filter_trap_r <= 1'b1;
                                                end else if ((heap_ptr_r +
                                                        pycore_tuple_alloc_bytes(
                                                            {16'b0, extra})) >
                                                        PYCORE_HEAP_LIMIT) begin
                                                    container_mem_fault_r <= 1'b1;
                                                end else begin
                                                    container_count_r <= extra[6:0];
                                                    container_base_r  <= heap_ptr_r;
                                                    if (extra == 16'd0) begin
                                                        container_wb_we_r <= 1'b1;
                                                        container_wb_addr_r <= RF_AW'(
                                                            call_new_locals_r +
                                                            call_total_params_r[
                                                                RF_AW-1:0]);
                                                        container_wb_data_r <=
                                                            pycore_make_entry(
                                                                PY_TAG_TUPLE,
                                                                {64'd0,
                                                                 {32'b0, heap_ptr_r}});
                                                        call_argcount_r <=
                                                            call_total_params_r + 16'd1;
                                                        call_sub_r <= 6'd24;
                                                    end else begin
                                                        heap_ptr_r <= heap_ptr_r +
                                                            pycore_tuple_alloc_bytes(
                                                                {16'b0, extra});
                                                        container_idx_r <= 7'd0;
                                                        container_rf_addr_r <= RF_AW'(
                                                            call_new_locals_r +
                                                            call_meta_argc_r[
                                                                RF_AW-1:0]);
                                                        call_sub_r <= 6'd21;
                                                    end
                                                end
                                            end
                                        end
                                    end
                                    6'd21: begin
                                        container_tag_r <= cont_rf_rs1_tag;
                                        container_val_r <= cont_rf_rs1_val;
                                        container_dmem_addr_r <= pycore_tuple_val_addr(
                                            container_base_r, {25'b0, container_idx_r});
                                        container_dmem_we_r      <= 1'b1;
                                        container_dmem_wdata_r   <= cont_rf_rs1_val;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd22;
                                    end
                                    6'd22: begin
                                        container_dmem_addr_r <= pycore_tuple_tag_addr(
                                            container_base_r, {25'b0, container_idx_r});
                                        container_dmem_we_r      <= 1'b1;
                                        container_dmem_wdata_r   <= {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd23;
                                    end
                                    6'd23: begin
                                        if ((container_idx_r + 7'd1) <
                                                container_count_r) begin
                                            container_idx_r <= container_idx_r + 7'd1;
                                            container_rf_addr_r <= RF_AW'(
                                                call_new_locals_r +
                                                call_meta_argc_r[RF_AW-1:0] +
                                                container_idx_r[RF_AW-1:0] +
                                                RF_AW'(1));
                                            call_sub_r <= 6'd21;
                                        end else begin
                                            container_wb_we_r <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(
                                                call_new_locals_r +
                                                call_total_params_r[RF_AW-1:0]);
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_TUPLE,
                                                {{57'b0, container_count_r},
                                                 {32'b0, container_base_r}});
                                            call_argcount_r <=
                                                call_total_params_r + 16'd1;
                                            call_sub_r <= 6'd24;
                                        end
                                    end
                                    6'd24: begin
                                        if (call_varargs_to_frame_r) begin
                                            call_phase_r <= 4'd7;
                                        end else begin
                                            // Pack leaves container_idx at
                                            // extra-1; KW bind uses it as the
                                            // names/kwargs index — reset.
                                            container_idx_r <= 7'd0;
                                            call_sub_r <= call_after_varargs_sub_r;
                                        end
                                    end
                                    6'd25: begin
                                        // EX_KW kwargs dict: read used count.
                                        container_dmem_addr_r <=
                                            call_kw_names_r[31:0];
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd48;
                                    end

                                    // ------------------------------------------
                                    // KW / EX_KW binder (subs 32–55)
                                    // ------------------------------------------
                                    // 32: latch defaults; read co_varnames
                                    6'd32: begin
                                        call_defaults_r     <= container_rd_data_r;
                                        call_defaults_len_r <=
                                            container_rd_data_r[79:64];
                                        container_dmem_addr_r <=
                                            pycore_code_field_val_addr(
                                                call_code_addr_r,
                                                PYCORE_CODE_FIELD_CO_VARNAMES);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd33;
                                    end
                                    // 33: latch varnames; read co_kwdefaults
                                    6'd33: begin
                                        call_varnames_r <= container_rd_data_r;
                                        container_dmem_addr_r <=
                                            pycore_code_field_val_addr(
                                                call_code_addr_r,
                                                PYCORE_CODE_FIELD_CO_KWDEFAULTS);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd34;
                                    end
                                    // 34: validate; start kw value scratch copy
                                    //     or clear unfilled param slots.
                                    6'd34: begin
                                        call_kwdefaults_r <= container_rd_data_r;
                                        begin
                                            logic [15:0] def_len;
                                            logic [15:0] meta_ac;
                                            logic [15:0] min_ac;
                                            logic [15:0] n_pos_eff;
                                            logic [15:0] filled_pos;
                                            logic [15:0] local_slots;
                                            def_len = call_defaults_len_r;
                                            meta_ac = call_meta_argc_r;
                                            // Method form: slot0 is self; pos
                                            // args start at 1. call_argcount_r
                                            // already includes self when method.
                                            if (call_argcount_r >
                                                    {8'b0, call_n_pos_r})
                                                n_pos_eff = {8'b0, call_n_pos_r}
                                                            + 16'd1;
                                            else
                                                n_pos_eff = {8'b0, call_n_pos_r};
                                            filled_pos = (n_pos_eff > meta_ac) ?
                                                meta_ac : n_pos_eff;
                                            local_slots = call_total_params_r +
                                                (call_varargs_r ? 16'd1 : 16'd0) +
                                                (call_varkw_r ? 16'd1 : 16'd0);
                                            if (def_len > meta_ac) begin
                                                call_filter_trap_r <= 1'b1;
                                            end else if (!call_varargs_r &&
                                                    (n_pos_eff > meta_ac)) begin
                                                // Positional into kw-only.
                                                call_filter_trap_r <= 1'b1;
                                            end else if (
                                                    local_slots > 16'd32) begin
                                                call_filter_trap_r <= 1'b1;
                                            end else if ((9'(call_new_locals_r)
                                                          + 9'(call_nlocals_r))
                                                         > 9'(STACK_TOP_MAX)) begin
                                                call_filter_trap_r <= 1'b1;
                                            end else begin
                                                min_ac = meta_ac - def_len;
                                                call_min_argc_r <= min_ac;
                                                // filled_mask in call_range_start_r
                                                call_range_start_r <=
                                                    (filled_pos == 16'd0) ? 128'd0 :
                                                    ((128'd1 << filled_pos) - 128'd1);
                                                call_varargs_to_frame_r <= 1'b0;
                                                // Freeze KW stack bases before
                                                // *args packing mutates argc.
                                                call_kw_val_base_r <= call_argcount_r;
                                                call_kw_scratch_base_r <=
                                                    call_kw_scratch_base_now;
                                                if ((call_mode_r == CALL_MODE_KW) &&
                                                    (call_n_kwargs_r != 8'd0)) begin
                                                    container_idx_r <= 7'd0;
                                                    call_sub_r <= 6'd35;
                                                end else if (
                                                    call_mode_r == CALL_MODE_EX_KW) begin
                                                    call_after_varargs_sub_r <= 6'd25;
                                                    call_sub_r <= 6'd20;
                                                end else begin
                                                    // No kwargs: defaults only.
                                                    container_idx_r <= 7'd0;
                                                    call_after_varargs_sub_r <= 6'd42;
                                                    call_sub_r <= 6'd20;
                                                end
                                            end
                                        end
                                    end
                                    // 35: copy kwargs[i] → scratch[i] (RF).
                                    // Incoming kwargs sit at locals[val_base+i]
                                    // (free: val_base==n_pos; method: includes
                                    // self so kwargs start after self+positionals).
                                    // Bases were latched in sub 34.
                                    6'd35: begin
                                        container_rf_addr_r <= RF_AW'(
                                            call_new_locals_r
                                            + call_kw_val_base_r[RF_AW-1:0]
                                            + {1'b0, container_idx_r});
                                        call_sub_r <= 6'd36;
                                    end
                                    6'd36: begin
                                        // Scratch lives past self/pos/kwargs and
                                        // above *args / **kwargs when needed.
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(
                                            call_new_locals_r
                                            + call_kw_scratch_base_r[RF_AW-1:0]
                                            + {1'b0, container_idx_r});
                                        container_wb_data_r <= pycore_make_entry(
                                            cont_rf_rs1_tag, cont_rf_rs1_val);
                                        if (({1'b0, container_idx_r} + 8'd1) >=
                                                call_n_kwargs_r) begin
                                            container_idx_r <= 7'd0;
                                            call_after_varargs_sub_r <= 6'd37;
                                            call_sub_r <= 6'd20;
                                        end else begin
                                            container_idx_r <=
                                                container_idx_r + 7'd1;
                                            call_sub_r <= 6'd35;
                                        end
                                    end
                                    // 37: bind names[j] — read name val
                                    6'd37: begin
                                        container_dmem_addr_r <=
                                            pycore_tuple_val_addr(
                                                call_kw_names_r[31:0],
                                                {25'b0, container_idx_r});
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd38;
                                    end
                                    6'd38: begin
                                        container_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <=
                                            pycore_tuple_tag_addr(
                                                call_kw_names_r[31:0],
                                                {25'b0, container_idx_r});
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd39;
                                    end
                                    // 39: latch name; start varname scan k=0
                                    6'd39: begin
                                        if (!pycore_is_string_tag(
                                                container_rd_data_r[3:0])) begin
                                            call_filter_trap_r <= 1'b1;
                                        end else begin
                                            container_tag_r <=
                                                container_rd_data_r[3:0];
                                            // k in call_range_step_r[6:0]
                                            call_range_step_r <= 128'd0;
                                            call_sub_r <= 6'd40;
                                        end
                                    end
                                    // 40: read varnames[k] val/tag; compare
                                    6'd40: begin
                                        if (call_range_step_r[15:0] >=
                                                call_total_params_r) begin
                                            // No formal left to try (callee has
                                            // none at all, or *args / **kwargs
                                            // names follow).  Sub 56 handles it
                                            // as "no match" without a read.
                                            call_sub_r <= 6'd56;
                                        end else begin
                                            container_dmem_addr_r <=
                                                pycore_tuple_val_addr(
                                                    call_varnames_r[31:0],
                                                    call_range_step_r[31:0]);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_sub_r <= 6'd41;
                                        end
                                    end
                                    6'd41: begin
                                        call_range_stop_r <= container_rd_data_r;
                                        container_dmem_addr_r <=
                                            pycore_tuple_tag_addr(
                                                call_varnames_r[31:0],
                                                call_range_step_r[31:0]);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd56;
                                    end
                                    // 56: compare name vs varnames[k]
                                    6'd56: begin
                                        begin
                                            logic in_range;
                                            logic name_match;
                                            logic posonly_hit;
                                            logic exhausted;
                                            in_range = (call_range_step_r[15:0] <
                                                        call_total_params_r);
                                            name_match = in_range &&
                                                pycore_dict_key_rich_eq(
                                                    container_tag_r,
                                                    container_val_r,
                                                    container_rd_data_r[3:0],
                                                    call_range_stop_r);
                                            // A positional-only formal never
                                            // accepts a keyword of the same
                                            // name — it is "unexpected" too.
                                            posonly_hit = name_match &&
                                                (call_range_step_r[15:0] <
                                                 call_posonly_r);
                                            exhausted = !name_match &&
                                                ((call_range_step_r[15:0] +
                                                  16'd1) >=
                                                 call_total_params_r);
                                            if (posonly_hit || exhausted) begin
                                                // Unexpected keyword: **kwargs
                                                // takes it, otherwise TypeError.
                                                if (!call_varkw_r) begin
                                                    call_filter_trap_r <= 1'b1;
                                                end else if ((call_mode_r ==
                                                        CALL_MODE_EX_KW) &&
                                                        (container_order_idx_r[31:7]
                                                         != 25'b0)) begin
                                                    // Leftover mask only spans
                                                    // 128 keyword indices.
                                                    call_filter_trap_r <= 1'b1;
                                                end else if (call_mode_r ==
                                                        CALL_MODE_EX_KW) begin
                                                    call_varkw_left_r <=
                                                        call_varkw_left_r |
                                                        (128'd1 <<
                                                         container_order_idx_r[6:0]);
                                                    if ((container_order_idx_r
                                                         + 32'd1) >=
                                                            container_order_len_r[31:0])
                                                    begin
                                                        container_idx_r <= 7'd0;
                                                        call_sub_r <= 6'd42;
                                                    end else begin
                                                        container_order_idx_r <=
                                                            container_order_idx_r
                                                            + 32'd1;
                                                        container_dmem_addr_r <=
                                                            pycore_dict_order_val_addr(
                                                                container_order_ptr_r,
                                                                container_order_idx_r
                                                                + 32'd1);
                                                        container_dmem_we_r <= 1'b0;
                                                        container_dmem_pending_r
                                                            <= 1'b1;
                                                        call_sub_r <= 6'd50;
                                                    end
                                                end else begin
                                                    call_varkw_left_r <=
                                                        call_varkw_left_r |
                                                        (128'd1 <<
                                                         container_idx_r);
                                                    if (({1'b0, container_idx_r}
                                                         + 8'd1) >=
                                                            call_n_kwargs_r) begin
                                                        container_idx_r <= 7'd0;
                                                        call_sub_r <= 6'd42;
                                                    end else begin
                                                        container_idx_r <=
                                                            container_idx_r + 7'd1;
                                                        call_sub_r <= 6'd37;
                                                    end
                                                end
                                            end else if (name_match) begin
                                                // Found slot k — check filled bit
                                                if (call_range_start_r[
                                                        call_range_step_r[4:0]]) begin
                                                    call_filter_trap_r <= 1'b1;
                                                end else if (call_mode_r ==
                                                             CALL_MODE_EX_KW) begin
                                                    // Value via kwargs dict probe.
                                                    container_base_r <=
                                                        call_kw_names_r[31:0];
                                                    container_dmem_addr_r <=
                                                        call_kw_names_r[31:0];
                                                    container_dmem_we_r <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                    call_sub_r <= 6'd58;
                                                end else begin
                                                    // CALL_KW: value from scratch[j]
                                                    container_rf_addr_r <= RF_AW'(
                                                        call_new_locals_r
                                                        + call_kw_scratch_base_r[
                                                            RF_AW-1:0]
                                                        + {1'b0, container_idx_r});
                                                    call_sub_r <= 6'd57;
                                                end
                                            end else begin
                                                call_range_step_r <=
                                                    call_range_step_r + 128'd1;
                                                call_sub_r <= 6'd40;
                                            end
                                        end
                                    end
                                    // 57: write scratch value into locals[k]
                                    6'd57: begin
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(
                                            call_new_locals_r
                                            + call_range_step_r[RF_AW-1:0]);
                                        container_wb_data_r <= pycore_make_entry(
                                            cont_rf_rs1_tag, cont_rf_rs1_val);
                                        call_range_start_r <= call_range_start_r
                                            | (128'd1 << call_range_step_r[4:0]);
                                        if (({1'b0, container_idx_r} + 8'd1) >=
                                                call_n_kwargs_r) begin
                                            container_idx_r <= 7'd0;
                                            call_sub_r <= 6'd42;
                                        end else begin
                                            container_idx_r <=
                                                container_idx_r + 7'd1;
                                            call_sub_r <= 6'd37;
                                        end
                                    end

                                    // 42: fill positional defaults / check required
                                    //     container_idx walks 0 .. argcount-1
                                    6'd42: begin
                                        if (container_idx_r >=
                                                call_meta_argc_r[6:0]) begin
                                            container_idx_r <=
                                                call_meta_argc_r[6:0];
                                            call_sub_r <= 6'd45;
                                        end else if (call_range_start_r[
                                                         container_idx_r[4:0]]) begin
                                            container_idx_r <=
                                                container_idx_r + 7'd1;
                                            // stay in 42
                                        end else if ({9'b0, container_idx_r} <
                                                     {2'b0, call_min_argc_r[6:0]}) begin
                                            call_filter_trap_r <= 1'b1; // missing
                                        end else begin
                                            // defaults[idx - min]
                                            begin
                                                logic [31:0] def_i;
                                                def_i = {25'b0, container_idx_r}
                                                        - {16'b0, call_min_argc_r};
                                                container_dmem_addr_r <=
                                                    pycore_tuple_val_addr(
                                                        call_defaults_r[31:0], def_i);
                                            end
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_sub_r <= 6'd43;
                                        end
                                    end
                                    6'd43: begin
                                        container_val_r <= container_rd_data_r;
                                        begin
                                            logic [31:0] def_i;
                                            def_i = {25'b0, container_idx_r}
                                                    - {16'b0, call_min_argc_r};
                                            container_dmem_addr_r <=
                                                pycore_tuple_tag_addr(
                                                    call_defaults_r[31:0], def_i);
                                        end
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd44;
                                    end
                                    6'd44: begin
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <=
                                            call_new_locals_r
                                            + container_idx_r[RF_AW-1:0];
                                        container_wb_data_r <= pycore_make_entry(
                                            container_rd_data_r[3:0],
                                            container_val_r);
                                        call_range_start_r <= call_range_start_r
                                            | (128'd1 << container_idx_r[4:0]);
                                        container_idx_r <= container_idx_r + 7'd1;
                                        call_sub_r <= 6'd42;
                                    end

                                    // 45: kw-only slots — filled or kwdefaults
                                    6'd45: begin
                                        if ({9'b0, container_idx_r} >=
                                                {2'b0, call_total_params_r[6:0]}) begin
                                            // All params resolved.  CO_VARKEYWORDS
                                            // still owes the **kwargs local, even
                                            // when nothing was left over.
                                            if (call_varkw_r) begin
                                                call_varkw_step_r <= 5'd0;
                                                call_sub_r <= 6'd52;
                                            end else begin
                                                call_argcount_r <= call_total_params_r
                                                    + (call_varargs_r ? 16'd1 : 16'd0);
                                                call_sub_r <= 6'd0;
                                                call_phase_r <= 4'd7;
                                            end
                                        end else if (call_range_start_r[
                                                         container_idx_r[4:0]]) begin
                                            container_idx_r <=
                                                container_idx_r + 7'd1;
                                        end else if (!pycore_is_dict(
                                                         PY_TAG_MUT_COLLEC,
                                                         call_kwdefaults_r)) begin
                                            call_filter_trap_r <= 1'b1;
                                        end else begin
                                            // Probe kwdefaults for varnames[idx]
                                            container_dmem_addr_r <=
                                                pycore_tuple_val_addr(
                                                    call_varnames_r[31:0],
                                                    {25'b0, container_idx_r});
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_sub_r <= 6'd46;
                                        end
                                    end
                                    6'd46: begin
                                        container_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <=
                                            pycore_tuple_tag_addr(
                                                call_varnames_r[31:0],
                                                {25'b0, container_idx_r});
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd47;
                                    end
                                    // 47: start dict probe on kwdefaults
                                    6'd47: begin
                                        if (!pycore_is_string_tag(
                                                container_rd_data_r[3:0])) begin
                                            call_filter_trap_r <= 1'b1;
                                        end else begin
                                            container_tag_r <=
                                                container_rd_data_r[3:0];
                                            container_base_r <=
                                                call_kwdefaults_r[31:0];
                                            container_dmem_addr_r <=
                                                call_kwdefaults_r[31:0];
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_sub_r <= 6'd58;
                                        end
                                    end
                                    // 58: kwdefaults header → table_ptr
                                    6'd58: begin
                                        container_slot_count_r <=
                                            cont_dict_hdr_slots[31:0];
                                        container_used_r <=
                                            cont_dict_hdr_used;
                                        container_dmem_addr_r <=
                                            pycore_dict_table_ptr_addr(
                                                container_base_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd59;
                                    end
                                    6'd59: begin
                                        container_buf_r <= cont_dict_table_ptr;
                                        if ((container_slot_count_r == 32'd0) ||
                                            (cont_dict_table_ptr == 32'd0) ||
                                            (container_used_r == 64'd0)) begin
                                            call_filter_trap_r <= 1'b1; // missing
                                        end else begin
                                            begin
                                                logic [31:0] probe0;
                                                probe0 = pycore_dict_key_hash(
                                                    container_tag_r,
                                                    container_val_r)
                                                    & (container_slot_count_r
                                                       - 32'd1);
                                                container_probe_r   <= probe0;
                                                container_probe_n_r <= 32'd0;
                                                container_dmem_addr_r <=
                                                    pycore_dict_ktag_addr(
                                                        cont_dict_table_ptr,
                                                        probe0);
                                            end
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_sub_r <= 6'd60;
                                        end
                                    end
                                    // 60: probe ktag
                                    6'd60: begin
                                        if (container_rd_data_r[3:0] == 4'd0) begin
                                            call_filter_trap_r <= 1'b1; // miss
                                        end else if (pycore_dict_tombstone(
                                                         container_rd_data_r[3:0])) begin
                                            container_probe_n_r <=
                                                container_probe_n_r + 32'd1;
                                            if ((container_probe_n_r + 32'd1) >=
                                                    container_slot_count_r) begin
                                                call_filter_trap_r <= 1'b1;
                                            end else begin
                                                container_probe_r <=
                                                    (container_probe_r + 32'd1)
                                                    & (container_slot_count_r
                                                       - 32'd1);
                                                container_dmem_addr_r <=
                                                    pycore_dict_ktag_addr(
                                                        container_buf_r,
                                                        (container_probe_r + 32'd1)
                                                        & (container_slot_count_r
                                                           - 32'd1));
                                                container_dmem_we_r <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                            end
                                        end else begin
                                            call_self_tag_r <=
                                                container_rd_data_r[3:0];
                                            container_dmem_addr_r <=
                                                pycore_dict_kval_addr(
                                                    container_buf_r,
                                                    container_probe_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_sub_r <= 6'd61;
                                        end
                                    end
                                    6'd61: begin
                                        if (!pycore_dict_key_rich_eq(
                                                container_tag_r,
                                                container_val_r,
                                                call_self_tag_r,
                                                container_rd_data_r)) begin
                                            container_probe_n_r <=
                                                container_probe_n_r + 32'd1;
                                            if ((container_probe_n_r + 32'd1) >=
                                                    container_slot_count_r) begin
                                                call_filter_trap_r <= 1'b1;
                                            end else begin
                                                container_probe_r <=
                                                    (container_probe_r + 32'd1)
                                                    & (container_slot_count_r
                                                       - 32'd1);
                                                container_dmem_addr_r <=
                                                    pycore_dict_ktag_addr(
                                                        container_buf_r,
                                                        (container_probe_r + 32'd1)
                                                        & (container_slot_count_r
                                                           - 32'd1));
                                                container_dmem_we_r <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                call_sub_r <= 6'd60;
                                            end
                                        end else begin
                                            // Read value
                                            container_dmem_addr_r <=
                                                pycore_dict_vval_addr(
                                                    container_buf_r,
                                                    container_probe_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_sub_r <= 6'd62;
                                        end
                                    end
                                    6'd62: begin
                                        call_range_stop_r <= container_rd_data_r;
                                        container_dmem_addr_r <=
                                            pycore_dict_vtag_addr(
                                                container_buf_r,
                                                container_probe_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd63;
                                    end
                                    6'd63: begin
                                        // Write probed dict value into a local.
                                        // Shared probe (58-63) serves both:
                                        //   - EX_KW caller kwargs (order walk)
                                        //   - kwdefaults fill (container_idx)
                                        // Distinguish by which dict we probed;
                                        // EX_KW + kwdefaults must NOT take the
                                        // order-walk arm (hang / wrong slot).
                                        if ((call_mode_r == CALL_MODE_EX_KW) &&
                                            (container_base_r ==
                                             call_kw_names_r[31:0])) begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(
                                                call_new_locals_r
                                                + call_range_step_r[RF_AW-1:0]);
                                            container_wb_data_r <=
                                                pycore_make_entry(
                                                    container_rd_data_r[3:0],
                                                    call_range_stop_r);
                                            call_range_start_r <=
                                                call_range_start_r
                                                | (128'd1 <<
                                                   call_range_step_r[4:0]);
                                            if (container_order_idx_r + 32'd1 >=
                                                    container_order_len_r[31:0]) begin
                                                container_idx_r <= 7'd0;
                                                call_sub_r <= 6'd42;
                                            end else begin
                                                container_order_idx_r <=
                                                    container_order_idx_r + 32'd1;
                                                container_dmem_addr_r <=
                                                    pycore_dict_order_val_addr(
                                                        container_order_ptr_r,
                                                        container_order_idx_r
                                                        + 32'd1);
                                                container_dmem_we_r <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                call_sub_r <= 6'd50;
                                            end
                                        end else begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <=
                                                call_new_locals_r
                                                + container_idx_r[RF_AW-1:0];
                                            container_wb_data_r <=
                                                pycore_make_entry(
                                                    container_rd_data_r[3:0],
                                                    call_range_stop_r);
                                            call_range_start_r <=
                                                call_range_start_r
                                                | (128'd1 <<
                                                   container_idx_r[4:0]);
                                            container_idx_r <=
                                                container_idx_r + 7'd1;
                                            call_sub_r <= 6'd45;
                                        end
                                    end

                                    // ---- EX_KW: iterate kwargs dict by order ----
                                    // Order sidecar stores keys (val+tag); values
                                    // are recovered by hashing into the table.
                                    // 48: latch used; read order/table ptrs
                                    6'd48: begin
                                        container_used_r <=
                                            cont_dict_hdr_used;
                                        container_slot_count_r <=
                                            cont_dict_hdr_slots[31:0];
                                        container_base_r <=
                                            call_kw_names_r[31:0];
                                        if (cont_dict_hdr_used == 64'd0) begin
                                            container_idx_r <= 7'd0;
                                            call_sub_r <= 6'd42;
                                        end else begin
                                            container_dmem_addr_r <=
                                                pycore_dict_table_ptr_addr(
                                                    call_kw_names_r[31:0]);
                                            container_dmem_we_r <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_sub_r <= 6'd49;
                                        end
                                    end
                                    6'd49: begin
                                        container_buf_r <= cont_dict_table_ptr;
                                        container_order_ptr_r <=
                                            cont_dict_order_ptr;
                                        container_order_len_r <=
                                            container_used_r;
                                        container_order_idx_r <= 32'd0;
                                        container_dmem_addr_r <=
                                            pycore_dict_order_val_addr(
                                                cont_dict_order_ptr, 32'd0);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd50;
                                    end
                                    // 50: order key val → tag
                                    6'd50: begin
                                        container_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <=
                                            pycore_dict_order_tag_addr(
                                                container_order_ptr_r,
                                                container_order_idx_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd51;
                                    end
                                    // 51: start varname scan for this key
                                    6'd51: begin
                                        if (!pycore_is_string_tag(
                                                container_rd_data_r[3:0])) begin
                                            call_filter_trap_r <= 1'b1;
                                        end else begin
                                            container_tag_r <=
                                                container_rd_data_r[3:0];
                                            call_range_step_r <= 128'd0;
                                            call_sub_r <= 6'd40;
                                        end
                                    end

                                    // ------------------------------------------
                                    // CO_VARKEYWORDS pack (subs 52-55).
                                    // Keywords that bound to no formal were
                                    // recorded in call_varkw_left_r; they are
                                    // inserted into a fresh dict installed as the
                                    // last local (after positionals, kw-only and
                                    // *args).  The dict is pre-sized for every
                                    // caller keyword, so no grow can happen here.
                                    // Nested progress lives in call_varkw_step_r;
                                    // the dict itself in call_varkw_dict_r.
                                    // ------------------------------------------
                                    // 52: allocate object + order + table,
                                    //     write the header with used = 0.
                                    6'd52: begin
                                        if (call_varkw_alloced_r) begin
                                            call_varkw_step_r <= 5'd0;
                                            call_sub_r <= 6'd53;
                                        end else begin
                                            logic [6:0]  n_kw;
                                            logic [31:0] slots;
                                            // Upper bound on leftovers: the
                                            // caller's keyword count.
                                            if (call_varkw_left_r == 128'd0)
                                                n_kw = 7'd0;
                                            else if (call_mode_r == CALL_MODE_EX_KW)
                                                n_kw = container_order_len_r[6:0];
                                            else
                                                n_kw = call_n_kwargs_r[6:0];
                                            slots = pycore_dict_min_slots(n_kw);
                                            if ((heap_ptr_r +
                                                    pycore_dict_alloc_bytes(slots)) >
                                                    PYCORE_HEAP_LIMIT) begin
                                                container_mem_fault_r <= 1'b1;
                                            end else begin
                                                heap_ptr_r <= heap_ptr_r +
                                                    pycore_dict_alloc_bytes(slots);
                                                call_varkw_dict_r <=
                                                    {64'b0, slots, heap_ptr_r};
                                                call_varkw_alloced_r <= 1'b1;
                                                container_used_r <= 64'd0;
                                                container_dmem_addr_r  <= heap_ptr_r;
                                                container_dmem_we_r    <= 1'b1;
                                                container_dmem_wdata_r <=
                                                    pycore_dict_header(
                                                        {32'b0, slots}, 64'd0);
                                                container_dmem_pending_r <= 1'b1;
                                                call_varkw_step_r <= 5'd0;
                                                call_sub_r <= 6'd53;
                                            end
                                        end
                                    end
                                    // 53: dict metadata word, then the packed
                                    //     {order_ptr, table_ptr} slot.
                                    6'd53: begin
                                        if (call_varkw_step_r == 5'd0) begin
                                            container_dmem_addr_r <=
                                                pycore_dict_meta_addr(
                                                    cont_varkw_base);
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <= 128'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_varkw_step_r <= 5'd1;
                                        end else begin
                                            container_dmem_addr_r <=
                                                pycore_dict_table_ptr_addr(
                                                    cont_varkw_base);
                                            container_dmem_we_r <= 1'b1;
                                            container_dmem_wdata_r <= {
                                                32'b0, cont_varkw_order_ptr,
                                                32'b0, cont_varkw_table_ptr
                                            };
                                            container_dmem_pending_r <= 1'b1;
                                            container_idx_r   <= 7'd0;
                                            call_varkw_step_r <= 5'd0;
                                            call_sub_r <= 6'd54;
                                        end
                                    end
                                    // 54: insert leftovers one at a time.
                                    //   step 0     : walk the leftover mask
                                    //   steps 1-3  : CALL_KW key + scratch value
                                    //   steps 8-11 : EX_KW key from order sidecar
                                    //   steps 4-7  : EX_KW value from the table
                                    //   steps 12-17: insert into the new dict
                                    6'd54: begin
                                        unique case (call_varkw_step_r)
                                        5'd0: begin
                                            if (call_varkw_left_r == 128'd0) begin
                                                call_varkw_step_r <= 5'd0;
                                                call_sub_r <= 6'd55;
                                            end else if (!call_varkw_left_r[
                                                    container_idx_r]) begin
                                                container_idx_r <=
                                                    container_idx_r + 7'd1;
                                            end else if (call_mode_r ==
                                                    CALL_MODE_EX_KW) begin
                                                // Caller kwargs dict header.
                                                container_dmem_addr_r <=
                                                    call_kw_names_r[31:0];
                                                container_dmem_we_r <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                call_varkw_step_r <= 5'd8;
                                            end else begin
                                                // CALL_KW: key from names tuple.
                                                container_dmem_addr_r <=
                                                    pycore_tuple_val_addr(
                                                        call_kw_names_r[31:0],
                                                        {25'b0, container_idx_r});
                                                container_dmem_we_r <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                call_varkw_step_r <= 5'd1;
                                            end
                                        end
                                        5'd1: begin
                                            container_val_r <= container_rd_data_r;
                                            container_dmem_addr_r <=
                                                pycore_tuple_tag_addr(
                                                    call_kw_names_r[31:0],
                                                    {25'b0, container_idx_r});
                                            container_dmem_we_r <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_varkw_step_r <= 5'd2;
                                        end
                                        5'd2: begin
                                            container_tag_r <=
                                                container_rd_data_r[3:0];
                                            // Value still parked in the kw scratch.
                                            container_rf_addr_r <= RF_AW'(
                                                call_new_locals_r
                                                + call_kw_scratch_base_r[RF_AW-1:0]
                                                + {1'b0, container_idx_r});
                                            call_varkw_step_r <= 5'd3;
                                        end
                                        5'd3: begin
                                            // Latch value, start the insert probe.
                                            logic [31:0] probe0;
                                            call_range_stop_r <= cont_rf_rs1_val;
                                            call_range_step_r <=
                                                {124'b0, cont_rf_rs1_tag};
                                            probe0 = pycore_dict_key_hash(
                                                container_tag_r, container_val_r)
                                                & (cont_varkw_slots - 32'd1);
                                            container_probe_r   <= probe0;
                                            container_probe_n_r <= 32'd0;
                                            container_dmem_addr_r <=
                                                pycore_dict_ktag_addr(
                                                    cont_varkw_table_ptr, probe0);
                                            container_dmem_we_r <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_varkw_step_r <= 5'd12;
                                        end
                                        // EX_KW: re-read the caller kwargs dict.
                                        5'd8: begin
                                            container_slot_count_r <=
                                                cont_dict_hdr_slots[31:0];
                                            container_dmem_addr_r <=
                                                pycore_dict_table_ptr_addr(
                                                    call_kw_names_r[31:0]);
                                            container_dmem_we_r <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_varkw_step_r <= 5'd9;
                                        end
                                        5'd9: begin
                                            container_buf_r <= cont_dict_table_ptr;
                                            container_order_ptr_r <=
                                                cont_dict_order_ptr;
                                            container_dmem_addr_r <=
                                                pycore_dict_order_val_addr(
                                                    cont_dict_order_ptr,
                                                    {25'b0, container_idx_r});
                                            container_dmem_we_r <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_varkw_step_r <= 5'd10;
                                        end
                                        5'd10: begin
                                            container_val_r <= container_rd_data_r;
                                            container_dmem_addr_r <=
                                                pycore_dict_order_tag_addr(
                                                    container_order_ptr_r,
                                                    {25'b0, container_idx_r});
                                            container_dmem_we_r <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_varkw_step_r <= 5'd11;
                                        end
                                        5'd11: begin
                                            // Key complete; probe the caller
                                            // table for its value.
                                            logic [31:0] probe0;
                                            container_tag_r <=
                                                container_rd_data_r[3:0];
                                            probe0 = pycore_dict_key_hash(
                                                container_rd_data_r[3:0],
                                                container_val_r)
                                                & (container_slot_count_r - 32'd1);
                                            container_probe_r   <= probe0;
                                            container_probe_n_r <= 32'd0;
                                            container_dmem_addr_r <=
                                                pycore_dict_ktag_addr(
                                                    container_buf_r, probe0);
                                            container_dmem_we_r <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_varkw_step_r <= 5'd4;
                                        end
                                        5'd4: begin
                                            if (pycore_dict_slot_empty(
                                                    container_rd_data_r)) begin
                                                call_filter_trap_r <= 1'b1; // miss
                                            end else if (pycore_dict_tombstone(
                                                    container_rd_data_r[3:0])) begin
                                                container_probe_n_r <=
                                                    container_probe_n_r + 32'd1;
                                                if ((container_probe_n_r + 32'd1) >=
                                                        container_slot_count_r) begin
                                                    call_filter_trap_r <= 1'b1;
                                                end else begin
                                                    container_probe_r <=
                                                        cont_probe_next;
                                                    container_dmem_addr_r <=
                                                        pycore_dict_ktag_addr(
                                                            container_buf_r,
                                                            cont_probe_next);
                                                    container_dmem_we_r <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                end
                                            end else begin
                                                call_self_tag_r <=
                                                    container_rd_data_r[3:0];
                                                container_dmem_addr_r <=
                                                    pycore_dict_kval_addr(
                                                        container_buf_r,
                                                        container_probe_r);
                                                container_dmem_we_r <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                call_varkw_step_r <= 5'd5;
                                            end
                                        end
                                        5'd5: begin
                                            if (!pycore_dict_key_rich_eq(
                                                    container_tag_r,
                                                    container_val_r,
                                                    call_self_tag_r,
                                                    container_rd_data_r)) begin
                                                container_probe_n_r <=
                                                    container_probe_n_r + 32'd1;
                                                if ((container_probe_n_r + 32'd1) >=
                                                        container_slot_count_r) begin
                                                    call_filter_trap_r <= 1'b1;
                                                end else begin
                                                    container_probe_r <=
                                                        cont_probe_next;
                                                    container_dmem_addr_r <=
                                                        pycore_dict_ktag_addr(
                                                            container_buf_r,
                                                            cont_probe_next);
                                                    container_dmem_we_r <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                    call_varkw_step_r <= 5'd4;
                                                end
                                            end else begin
                                                container_dmem_addr_r <=
                                                    pycore_dict_vval_addr(
                                                        container_buf_r,
                                                        container_probe_r);
                                                container_dmem_we_r <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                call_varkw_step_r <= 5'd6;
                                            end
                                        end
                                        5'd6: begin
                                            call_range_stop_r <= container_rd_data_r;
                                            container_dmem_addr_r <=
                                                pycore_dict_vtag_addr(
                                                    container_buf_r,
                                                    container_probe_r);
                                            container_dmem_we_r <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_varkw_step_r <= 5'd7;
                                        end
                                        5'd7: begin
                                            // Value complete; start insert probe.
                                            logic [31:0] probe0;
                                            call_range_step_r <=
                                                {124'b0, container_rd_data_r[3:0]};
                                            probe0 = pycore_dict_key_hash(
                                                container_tag_r, container_val_r)
                                                & (cont_varkw_slots - 32'd1);
                                            container_probe_r   <= probe0;
                                            container_probe_n_r <= 32'd0;
                                            container_dmem_addr_r <=
                                                pycore_dict_ktag_addr(
                                                    cont_varkw_table_ptr, probe0);
                                            container_dmem_we_r <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            call_varkw_step_r <= 5'd12;
                                        end
                                        // Insert key/value into the new dict.
                                        5'd12: begin
                                            if (pycore_dict_slot_empty(
                                                    container_rd_data_r)) begin
                                                container_dmem_addr_r <=
                                                    pycore_dict_kval_addr(
                                                        cont_varkw_table_ptr,
                                                        container_probe_r);
                                                container_dmem_we_r    <= 1'b1;
                                                container_dmem_wdata_r <=
                                                    container_val_r;
                                                container_dmem_pending_r <= 1'b1;
                                                call_varkw_step_r <= 5'd13;
                                            end else begin
                                                // Keys within one keyword source
                                                // are unique, so an occupied slot
                                                // is always a hash collision.
                                                container_probe_n_r <=
                                                    container_probe_n_r + 32'd1;
                                                if ((container_probe_n_r + 32'd1) >=
                                                        cont_varkw_slots) begin
                                                    container_mem_fault_r <= 1'b1;
                                                end else begin
                                                    container_probe_r <=
                                                        cont_varkw_probe_next;
                                                    container_dmem_addr_r <=
                                                        pycore_dict_ktag_addr(
                                                            cont_varkw_table_ptr,
                                                            cont_varkw_probe_next);
                                                    container_dmem_we_r <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                end
                                            end
                                        end
                                        5'd13: begin
                                            container_dmem_addr_r <=
                                                pycore_dict_ktag_addr(
                                                    cont_varkw_table_ptr,
                                                    container_probe_r);
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <=
                                                pycore_dict_key_tag_word(
                                                    container_tag_r,
                                                    container_val_r);
                                            container_dmem_pending_r <= 1'b1;
                                            call_varkw_step_r <= 5'd14;
                                        end
                                        5'd14: begin
                                            container_dmem_addr_r <=
                                                pycore_dict_vval_addr(
                                                    cont_varkw_table_ptr,
                                                    container_probe_r);
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <=
                                                call_range_stop_r;
                                            container_dmem_pending_r <= 1'b1;
                                            call_varkw_step_r <= 5'd15;
                                        end
                                        5'd15: begin
                                            container_dmem_addr_r <=
                                                pycore_dict_vtag_addr(
                                                    cont_varkw_table_ptr,
                                                    container_probe_r);
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <=
                                                {124'b0, call_range_step_r[3:0]};
                                            container_dmem_pending_r <= 1'b1;
                                            call_varkw_step_r <= 5'd16;
                                        end
                                        5'd16: begin
                                            // Order sidecar keeps insertion order.
                                            container_dmem_addr_r <=
                                                pycore_dict_order_val_addr(
                                                    cont_varkw_order_ptr,
                                                    container_used_r[31:0]);
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <=
                                                container_val_r;
                                            container_dmem_pending_r <= 1'b1;
                                            call_varkw_step_r <= 5'd17;
                                        end
                                        5'd17: begin
                                            container_dmem_addr_r <=
                                                pycore_dict_order_tag_addr(
                                                    cont_varkw_order_ptr,
                                                    container_used_r[31:0]);
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <=
                                                {124'b0, container_tag_r};
                                            container_dmem_pending_r <= 1'b1;
                                            container_used_r <=
                                                container_used_r + 64'd1;
                                            call_varkw_left_r <= call_varkw_left_r
                                                & ~(128'd1 << container_idx_r);
                                            container_idx_r <=
                                                container_idx_r + 7'd1;
                                            call_varkw_step_r <= 5'd0;
                                        end
                                        default: call_filter_trap_r <= 1'b1;
                                        endcase
                                    end
                                    // 55: publish used / order_len, install the
                                    //     dict as the **kwargs local, then frame.
                                    6'd55: begin
                                        if (call_varkw_step_r == 5'd0) begin
                                            container_dmem_addr_r  <=
                                                cont_varkw_base;
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <=
                                                pycore_dict_header(
                                                    {32'b0, cont_varkw_slots},
                                                    container_used_r);
                                            container_dmem_pending_r <= 1'b1;
                                            call_varkw_step_r <= 5'd1;
                                        end else if (call_varkw_step_r == 5'd1) begin
                                            container_dmem_addr_r <=
                                                pycore_dict_meta_addr(
                                                    cont_varkw_base);
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <=
                                                pycore_dict_meta(
                                                    container_used_r,
                                                    container_used_r);
                                            container_dmem_pending_r <= 1'b1;
                                            call_varkw_step_r <= 5'd2;
                                        end else begin
                                            // **kwargs follows positionals,
                                            // kw-only and *args.  Bump argcount
                                            // so the phase-7 UNINIT clear starts
                                            // above it.
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(
                                                call_new_locals_r
                                                + call_total_params_r[RF_AW-1:0]
                                                + (call_varargs_r ? RF_AW'(1)
                                                                  : RF_AW'(0)));
                                            container_wb_data_r <= pycore_make_mut(
                                                PY_MUT_DICT,
                                                {32'b0, cont_varkw_base}, 1'b0);
                                            call_argcount_r <= call_total_params_r
                                                + (call_varargs_r ? 16'd1 : 16'd0)
                                                + 16'd1;
                                            call_varkw_step_r <= 5'd0;
                                            call_sub_r   <= 6'd0;
                                            call_phase_r <= 4'd7;
                                        end
                                    end

                                    default: ;
                                endcase
                            end
                        end

                        // --------------------------------------------------
                        // Phase 16: CALL_KW names prelude
                        // --------------------------------------------------
                        CALL_PHASE_KW_NAMES: begin
                            if (cont_rf_rs1_tag != PY_TAG_TUPLE) begin
                                call_filter_trap_r <= 1'b1;
                            end else begin
                                begin
                                    logic [63:0] nksz;
                                    logic [15:0] nk;
                                    nksz = pycore_tuple_size(cont_rf_rs1_val);
                                    nk = nksz[15:0];
                                    if (nk > cur_arg_r[15:0]) begin
                                        call_filter_trap_r <= 1'b1;
                                    end else begin
                                        call_kw_names_r  <= cont_rf_rs1_val;
                                        call_n_kwargs_r  <= nk[7:0];
                                        call_n_pos_r     <=
                                            cur_arg_r[7:0] - nk[7:0];
                                        // Pop names; bases like plain CALL.
                                        call_new_locals_r <= RF_AW'(
                                            {2'b0, tos_r} - 9'd1
                                            - {2'b0, cur_arg_r[6:0]});
                                        call_tos_base_r <= RF_AW'(
                                            {2'b0, tos_r} - 9'd1
                                            - {2'b0, cur_arg_r[6:0]} - 9'd2);
                                        container_rf_addr_r <= RF_AW'(
                                            {2'b0, tos_r} - 9'd1
                                            - {2'b0, cur_arg_r[6:0]} - 9'd2);
                                        tos_r <= tos_r - RF_AW'(1);
                                        call_phase_r <= 5'd1;
                                    end
                                end
                            end
                        end

                        // --------------------------------------------------
                        // Phase 17–19: CALL_FUNCTION_EX
                        // --------------------------------------------------
                        CALL_PHASE_EX_KW: begin
                            if (pycore_is_null(
                                    cont_rf_rs1_tag, cont_rf_rs1_val)) begin
                                call_n_kwargs_r <= 8'd0;
                                tos_r <= tos_r - RF_AW'(1);
                                container_rf_addr_r <= RF_AW'(
                                    {2'b0, tos_r} - 9'd2);
                                call_phase_r <= CALL_PHASE_EX_ARGS;
                            end else if (pycore_is_dict(
                                             cont_rf_rs1_tag,
                                             cont_rf_rs1_val)) begin
                                call_kw_names_r <= cont_rf_rs1_val;
                                call_n_kwargs_r <= 8'd1; // flag: has kwargs dict
                                tos_r <= tos_r - RF_AW'(1);
                                container_rf_addr_r <= RF_AW'(
                                    {2'b0, tos_r} - 9'd2);
                                call_phase_r <= CALL_PHASE_EX_ARGS;
                            end else begin
                                call_filter_trap_r <= 1'b1;
                            end
                        end

                        CALL_PHASE_EX_ARGS: begin
                            if (cont_rf_rs1_tag == PY_TAG_TUPLE) begin
                                begin
                                    logic [63:0] tsz;
                                    tsz = pycore_tuple_size(cont_rf_rs1_val);
                                    call_args_is_list_r <= 1'b0;
                                    call_defaults_r <= cont_rf_rs1_val;
                                    call_n_pos_r <= tsz[7:0];
                                    tos_r <= tos_r - RF_AW'(1);
                                    if (tsz == 64'd0) begin
                                        cur_arg_r <= 32'd0;
                                        if (call_n_kwargs_r != 8'd0)
                                            call_mode_r <= CALL_MODE_EX_KW;
                                        else
                                            call_mode_r <= CALL_MODE_POS;
                                        call_phase_r <= 5'd0;
                                    end else begin
                                        container_idx_r <= 7'd0;
                                        container_dmem_addr_r <=
                                            pycore_tuple_val_addr(
                                                cont_rf_rs1_val[31:0], 32'd0);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_phase_r <= CALL_PHASE_EX_EXPAND;
                                        call_sub_r <= 6'd0;
                                    end
                                end
                            end else if (pycore_is_list(
                                             cont_rf_rs1_tag,
                                             cont_rf_rs1_val)) begin
                                call_args_is_list_r <= 1'b1;
                                call_obj_addr_r <= cont_rf_rs1_val[31:0];
                                tos_r <= tos_r - RF_AW'(1);
                                container_dmem_addr_r <= cont_rf_rs1_val[31:0];
                                container_dmem_we_r      <= 1'b0;
                                container_dmem_pending_r <= 1'b1;
                                call_phase_r <= CALL_PHASE_EX_EXPAND;
                                call_sub_r <= 6'd10; // list header
                            end else begin
                                call_filter_trap_r <= 1'b1;
                            end
                        end

                        CALL_PHASE_EX_EXPAND: begin
                            if (!container_dmem_pending_r) begin
                                unique case (call_sub_r)
                                    // Tuple expand: 0=val, 1=tag+push
                                    6'd0: begin
                                        container_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <=
                                            pycore_tuple_tag_addr(
                                                call_defaults_r[31:0],
                                                {25'b0, container_idx_r});
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd1;
                                    end
                                    6'd1: begin
                                        if ((9'(tos_r) + 9'd1) >
                                                9'(STACK_TOP_MAX)) begin
                                            call_filter_trap_r <= 1'b1;
                                        end else begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= tos_r;
                                            container_wb_data_r <=
                                                pycore_make_entry(
                                                    container_rd_data_r[3:0],
                                                    container_val_r);
                                            tos_r <= tos_r + RF_AW'(1);
                                            if (({1'b0, container_idx_r} + 8'd1) >=
                                                    call_n_pos_r) begin
                                                cur_arg_r <= {24'b0, call_n_pos_r};
                                                if (call_n_kwargs_r != 8'd0)
                                                    call_mode_r <= CALL_MODE_EX_KW;
                                                else
                                                    call_mode_r <= CALL_MODE_POS;
                                                call_phase_r <= 5'd0;
                                                call_sub_r <= 6'd0;
                                            end else begin
                                                container_idx_r <=
                                                    container_idx_r + 7'd1;
                                                container_dmem_addr_r <=
                                                    pycore_tuple_val_addr(
                                                        call_defaults_r[31:0],
                                                        {25'b0, container_idx_r}
                                                        + 32'd1);
                                                container_dmem_we_r <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                call_sub_r <= 6'd0;
                                            end
                                        end
                                    end
                                    // List: 10=header, 11=ob_item, then 0/1-like
                                    6'd10: begin
                                        begin
                                            logic [63:0] llen;
                                            llen = pycore_list_length(
                                                container_rd_data_r);
                                            call_n_pos_r <= llen[7:0];
                                            call_defaults_r[63:0] <= llen;
                                            if (llen == 64'd0) begin
                                                cur_arg_r <= 32'd0;
                                                if (call_n_kwargs_r != 8'd0)
                                                    call_mode_r <= CALL_MODE_EX_KW;
                                                else
                                                    call_mode_r <= CALL_MODE_POS;
                                                call_phase_r <= 5'd0;
                                                call_sub_r <= 6'd0;
                                            end else begin
                                                container_dmem_addr_r <=
                                                    pycore_list_obitem_addr(
                                                        call_obj_addr_r);
                                                container_dmem_we_r <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                call_sub_r <= 6'd11;
                                            end
                                        end
                                    end
                                    6'd11: begin
                                        container_buf_r <=
                                            container_rd_data_r[31:0];
                                        container_idx_r <= 7'd0;
                                        container_dmem_addr_r <=
                                            pycore_list_val_addr(
                                                container_rd_data_r[31:0],
                                                32'd0);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd12;
                                    end
                                    6'd12: begin
                                        container_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <=
                                            pycore_list_tag_addr(
                                                container_buf_r,
                                                {25'b0, container_idx_r});
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd13;
                                    end
                                    6'd13: begin
                                        if ((9'(tos_r) + 9'd1) >
                                                9'(STACK_TOP_MAX)) begin
                                            call_filter_trap_r <= 1'b1;
                                        end else begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= tos_r;
                                            container_wb_data_r <=
                                                pycore_make_entry(
                                                    container_rd_data_r[3:0],
                                                    container_val_r);
                                            tos_r <= tos_r + RF_AW'(1);
                                            if (({1'b0, container_idx_r} + 8'd1) >=
                                                    call_n_pos_r) begin
                                                cur_arg_r <= {24'b0, call_n_pos_r};
                                                if (call_n_kwargs_r != 8'd0)
                                                    call_mode_r <= CALL_MODE_EX_KW;
                                                else
                                                    call_mode_r <= CALL_MODE_POS;
                                                call_phase_r <= 5'd0;
                                                call_sub_r <= 6'd0;
                                            end else begin
                                                container_idx_r <=
                                                    container_idx_r + 7'd1;
                                                container_dmem_addr_r <=
                                                    pycore_list_val_addr(
                                                        container_buf_r,
                                                        {25'b0, container_idx_r}
                                                        + 32'd1);
                                                container_dmem_we_r <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                call_sub_r <= 6'd12;
                                            end
                                        end
                                    end
                                    default: call_filter_trap_r <= 1'b1;
                                endcase
                            end
                        end

                        default: ;
                    endcase
                end

                // ----------------------------------------------------------
                // S_RETURN: pop caller frame, re-read consts/names, then
                // commit return value (or saved instance under ret_discard).
                // ----------------------------------------------------------
                S_RETURN: begin
                    if (container_dmem_pending_r && dmem_ack_i) begin
                        container_dmem_pending_r <= 1'b0;
                        container_rd_data_r      <= dmem_rdata_i;
                    end

                    unique case (return_phase_r)

                        3'd0: begin
                            if (!call_sent_r && !frame_busy) begin
                                frame_return_valid_r <= 1'b1;
                                call_sent_r          <= 1'b1;
                            end

                            if (call_sent_r && frame_pop_req && !frame_dmem_pending_r) begin
                                frame_dmem_pending_r <= 1'b1;
                            end

                            if (frame_dmem_pending_r && dmem_ack_i) begin
                                frame_dmem_pending_r <= 1'b0;
                            end

                            if (frame_return_done) begin
                                cur_locals_base_r    <= frame_locals_base_out;
                                rf_set_locals_r      <= 1'b1;
                                rf_new_locals_r      <= frame_locals_base_out;
                                cur_code_r           <= frame_cur_code_out;
                                call_tos_base_r      <= frame_tos_base_out;
                                call_entry_slot_r    <= {32'b0, frame_pc_return_out};
                                // Callee ret-mode was packed into the frame at
                                // push; latch for writeback in phase 2.
                                frame_ret_mode_r     <= frame_ret_mode_out;
                                frame_saved_inst_r   <= frame_saved_inst_out;
                                call_sent_r          <= 1'b0;
                                frame_dmem_pending_r <= 1'b0;
                                container_dmem_addr_r    <= pycore_code_field_val_addr(
                                    frame_cur_code_out, PYCORE_CODE_FIELD_CO_CONSTS);
                                container_dmem_we_r      <= 1'b0;
                                container_dmem_pending_r <= 1'b1;
                                return_phase_r <= 3'd1;
                            end
                        end

                        3'd1: begin
                            if (!container_dmem_pending_r) begin
                                consts_base_r <= container_rd_data_r;
                                container_dmem_addr_r    <= pycore_code_field_val_addr(
                                    cur_code_r, PYCORE_CODE_FIELD_CO_NAMES);
                                container_dmem_we_r      <= 1'b0;
                                container_dmem_pending_r <= 1'b1;
                                return_phase_r <= 3'd2;
                            end
                        end

                        3'd2: begin
                            if (!container_dmem_pending_r) begin
                                names_base_r <= container_rd_data_r;
                                if (container_call_returning_r) begin
                                    // Restore the paused container instruction.
                                    // The normal CALL stack algebra below keeps
                                    // the returned value in RF; result_r gives
                                    // the resumed arm a stable copy even though
                                    // rs1_r will be restored to the iterator.
                                    // Protocol raise unwind (§6.1.1) restores
                                    // the same context but leaves call_exc_*
                                    // pending and does not set return_valid.
                                    container_op_r <= container_call_saved_op_r;
                                    container_phase_r <=
                                        container_call_saved_phase_r;
                                    cur_opcode_r <=
                                        container_call_saved_opcode_r;
                                    cur_arg_r <= container_call_saved_arg_r;
                                    cur_pc_r <= container_call_saved_pc_r;
                                    rs1_r <= container_call_saved_rs1_r;
                                    rs2_r <= container_call_saved_rs2_r;
                                    container_rf_addr_r <=
                                        container_call_saved_tos_r;
                                    container_call_active_r <= 1'b0;
                                    container_call_exc_unwind_r <= 1'b0;
                                    if (call_exc_pending_r) begin
                                        // Restore iterable/ITER under TOS; no
                                        // return value from the protocol CALL.
                                        return_wb_we_r   <= 1'b1;
                                        return_wb_addr_r <= call_tos_base_r;
                                        return_wb_data_r <=
                                            container_call_saved_rs1_r;
                                        tos_r <= call_tos_base_r + RF_AW'(1);
                                        redirect_pending_r <= 1'b1;
                                        redirect_tgt_r <=
                                            call_entry_slot_r[31:0];
                                        return_phase_r <= RET_PHASE_DONE;
                                    end else begin
                                        container_call_result_r <= rs1_r;
                                        container_call_return_valid_r <= 1'b1;
                                    end
                                end
                                if (!call_exc_pending_r) begin
                                    if (frame_ret_mode_r) begin
                                        // Discard __init__ return; require NONE.
                                        if (!pycore_is_none(
                                                pycore_get_tag(rs1_r),
                                                pycore_get_val(rs1_r))) begin
                                            return_type_trap_r <= 1'b1;
                                        end else begin
                                            return_wb_we_r   <= 1'b1;
                                            return_wb_addr_r <= call_tos_base_r;
                                            return_wb_data_r <= pycore_make_entry(
                                                PY_TAG_OBJECT,
                                                {{64{1'b0}}, frame_saved_inst_r});
                                            tos_r              <= call_tos_base_r
                                                                  + RF_AW'(1);
                                            redirect_pending_r <= 1'b1;
                                            redirect_tgt_r     <= call_entry_slot_r[31:0];
                                            return_phase_r     <= RET_PHASE_DONE;
                                        end
                                    end else begin
                                        return_wb_we_r     <= 1'b1;
                                        return_wb_addr_r   <= call_tos_base_r;
                                        return_wb_data_r   <= rs1_r;
                                        tos_r              <= call_tos_base_r + RF_AW'(1);
                                        redirect_pending_r <= 1'b1;
                                        redirect_tgt_r     <= call_entry_slot_r[31:0];
                                        return_phase_r     <= RET_PHASE_DONE;
                                    end
                                end
                            end
                        end

                        default: ;
                    endcase
                end
