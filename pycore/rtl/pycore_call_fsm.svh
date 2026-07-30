// pycore_call_fsm.svh — S_CALL / S_RETURN arms (included inside pycore_core).
//
// CALL phase map:
//   0  : bases from oparg; RF = callable
//   1  : CODE_OBJECT → 2; OBJECT → 8; else CALL_FILTER
//   2  : sentinel NULL → free (eff=oparg); else method (eff=oparg+1,
//        new_locals=tos-oparg-1); start entry_slot → 3
//   3–5: code fields entry_slot / co_consts / co_names
//   6  : metadata; start co_defaults → 14
//   7  : frame push + init
//   8–11: BOUND_METHOD unwrap (NULL sentinel required) → join 3
//   12 : TYPE instantiate + __init__ lookup (call_sub_r) → 3 or DONE
//   13 : OBK_BUILTIN — max/len/range on-core; else PY_TRAP_BUILTIN_CALL
//   14 : defaults arity check + fill missing locals → 7
//   15 : CALL_PHASE_DONE
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

                        4'd0: begin
                            // Bases from oparg (positional args excluding self).
                            call_new_locals_r <= RF_AW'(
                                {2'b0, tos_r} - {2'b0, cur_arg_r[6:0]});
                            call_tos_base_r   <= RF_AW'(
                                {2'b0, tos_r} - {2'b0, cur_arg_r[6:0]} - 9'd2);
                            container_rf_addr_r <= RF_AW'(
                                {2'b0, tos_r} - {2'b0, cur_arg_r[6:0]} - 9'd2);
                            call_phase_r <= 4'd1;
                        end

                        4'd1: begin
                            // Callable: CODE_OBJECT or OBJECT (BM / TYPE).
                            if (cont_rf_rs1_tag == PY_TAG_CODE_OBJECT) begin
                                call_code_addr_r    <= cont_rf_rs1_val[31:0];
                                container_rf_addr_r <= RF_AW'(
                                    {2'b0, tos_r} - {2'b0, cur_arg_r[6:0]} - 9'd1);
                                call_phase_r        <= 4'd2;
                            end else if (cont_rf_rs1_tag == PY_TAG_OBJECT) begin
                                call_obj_addr_r     <= cont_rf_rs1_val[31:0];
                                container_rf_addr_r <= RF_AW'(
                                    {2'b0, tos_r} - {2'b0, cur_arg_r[6:0]} - 9'd1);
                                call_sub_r          <= 6'd0;
                                call_phase_r        <= 4'd8;
                            end else begin
                                call_filter_trap_r <= 1'b1;
                            end
                        end

                        4'd2: begin
                            // Sentinel: NULL ⇒ free-function; else method form.
                            if (pycore_is_null(
                                    cont_rf_rs1_tag, cont_rf_rs1_val)) begin
                                call_argcount_r <= cur_arg_r[15:0];
                                // call_new_locals_r already tos - oparg
                            end else begin
                                call_argcount_r   <= cur_arg_r[15:0] + 16'd1;
                                call_new_locals_r <= RF_AW'(
                                    {2'b0, tos_r} - {2'b0, cur_arg_r[6:0]} - 9'd1);
                            end
                            container_dmem_addr_r    <= pycore_code_field_val_addr(
                                call_code_addr_r, PYCORE_CODE_FIELD_ENTRY_SLOT);
                            container_dmem_we_r      <= 1'b0;
                            container_dmem_pending_r <= 1'b1;
                            call_phase_r             <= 4'd3;
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
                                container_dmem_addr_r    <= pycore_code_field_val_addr(
                                    call_code_addr_r, PYCORE_CODE_FIELD_CO_DEFAULTS);
                                container_dmem_we_r      <= 1'b0;
                                container_dmem_pending_r <= 1'b1;
                                call_sub_r               <= 6'd0;
                                call_phase_r             <= 4'd14;
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
                                rf_init_frame_r      <= (call_argcount_r == 16'd0);
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
                        // Phases 8–11: OBJECT → BOUND_METHOD unwrap
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
                                    call_sub_r   <= 6'd0;
                                    call_phase_r <= 4'd12;
                                end else if (pycore_ob_kind(container_rd_data_r) ==
                                             PY_OBK_BUILTIN) begin
                                    // field0 = builtin_id
                                    container_dmem_addr_r <=
                                        pycore_obj_field_val_addr(
                                            call_obj_addr_r, 32'd0);
                                    container_dmem_we_r      <= 1'b0;
                                    container_dmem_pending_r <= 1'b1;
                                    call_sub_r               <= 6'd0;
                                    call_phase_r             <= 4'd13;
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
                                    call_argcount_r   <= cur_arg_r[15:0] + 16'd1;
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
                        //   sub3: MAX — read arg0 from RF
                        //   sub4: MAX — read arg1; compare; writeback
                        //   sub5: LEN — read arg0; dispatch by tag
                        //   sub6: LEN — list/dict header ready → push length
                        //   sub12–23: RANGE — normalize args, allocate object
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
                                // MAX arg0 — scratch in return_wb_data_r (entry-width).
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
                                // Allocate and write OBK_RANGE.
                                6'd15: begin
                                    if (call_range_step_r == 128'b0) begin
                                        container_type_trap_r <= 1'b1;
                                    end else if ((heap_ptr_r + PYCORE_OBJ_RANGE_BYTES) >
                                                 PYCORE_HEAP_LIMIT) begin
                                        container_mem_fault_r <= 1'b1;
                                    end else begin
                                        container_base_r <= heap_ptr_r;
                                        heap_ptr_r <= heap_ptr_r + PYCORE_OBJ_RANGE_BYTES;
                                        container_dmem_addr_r <= heap_ptr_r;
                                        container_dmem_we_r <= 1'b1;
                                        container_dmem_wdata_r <= pycore_pack_ob_head(
                                            PY_OBK_RANGE, 32'd0, 64'd0);
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd16;
                                    end
                                end
                                6'd16: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r <= container_base_r + 32'd16;
                                        container_dmem_we_r <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, PY_TAG_OBJECT};
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd17;
                                    end
                                end
                                6'd17: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r <= pycore_obj_field_val_addr(
                                            container_base_r, 32'd0);
                                        container_dmem_we_r <= 1'b1;
                                        container_dmem_wdata_r <= call_range_start_r;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd18;
                                    end
                                end
                                6'd18: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r <= pycore_obj_field_tag_addr(
                                            container_base_r, 32'd0);
                                        container_dmem_we_r <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, PY_TAG_INT};
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd19;
                                    end
                                end
                                6'd19: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r <= pycore_obj_field_val_addr(
                                            container_base_r, 32'd1);
                                        container_dmem_we_r <= 1'b1;
                                        container_dmem_wdata_r <= call_range_stop_r;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd20;
                                    end
                                end
                                6'd20: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r <= pycore_obj_field_tag_addr(
                                            container_base_r, 32'd1);
                                        container_dmem_we_r <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, PY_TAG_INT};
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd21;
                                    end
                                end
                                6'd21: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r <= pycore_obj_field_val_addr(
                                            container_base_r, 32'd2);
                                        container_dmem_we_r <= 1'b1;
                                        container_dmem_wdata_r <= call_range_step_r;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd22;
                                    end
                                end
                                6'd22: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r <= pycore_obj_field_tag_addr(
                                            container_base_r, 32'd2);
                                        container_dmem_we_r <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, PY_TAG_INT};
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd23;
                                    end
                                end
                                6'd23: begin
                                    if (!container_dmem_pending_r) begin
                                        container_wb_we_r <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(
                                            {2'b0, tos_r} -
                                            {2'b0, call_argcount_r[6:0]} - 9'd2);
                                        container_wb_data_r <= pycore_make_entry(
                                            PY_TAG_OBJECT,
                                            {{96{1'b0}}, container_base_r});
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
                                    if (cont_rf_rs1_tag == PY_TAG_LIST) begin
                                        container_src_buf_r <= cont_rf_rs1_val[31:0];
                                        container_dmem_addr_r <=
                                            cont_rf_rs1_val[31:0];
                                        container_dmem_we_r <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        call_sub_r <= 6'd25;
                                    end else if (cont_rf_rs1_tag ==
                                                 PY_TAG_TUPLE) begin
                                        if (pycore_tuple_size(
                                                cont_rf_rs1_val)[63:7] !=
                                            57'b0) begin
                                            container_type_trap_r <= 1'b1;
                                        end else begin
                                            container_src_buf_r <=
                                                cont_rf_rs1_val[31:0];
                                            container_src_len_r <=
                                                pycore_tuple_size(
                                                    cont_rf_rs1_val)[31:0];
                                            container_count_r <=
                                                pycore_tuple_size(
                                                    cont_rf_rs1_val)[6:0];
                                            call_sub_r <= 6'd27;
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
                                        container_wb_data_r <=
                                            pycore_make_entry(
                                                PY_TAG_SET,
                                                {{96{1'b0}},
                                                 container_base_r});
                                        tos_r <= RF_AW'(
                                            {2'b0, tos_r} -
                                            {2'b0,
                                             call_argcount_r[6:0]} - 9'd1);
                                        fetch_skip_r <= 1'b1;
                                        call_phase_r <= CALL_PHASE_DONE;
                                        call_sub_r <= 6'd0;
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
                                                {32'b0, container_base_r});
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
                                // 20: no __init__ — pop argc+2, push instance
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
                        // Phase 14: co_defaults arity + fill
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
                                            def_len = container_rd_data_r[79:64];
                                            meta_ac = call_meta_argc_r;
                                            if (def_len > meta_ac) begin
                                                call_filter_trap_r <= 1'b1;
                                            end else begin
                                                min_ac = meta_ac - def_len;
                                                call_min_argc_r <= min_ac;
                                                if ((call_argcount_r < min_ac) ||
                                                    (call_argcount_r > meta_ac)) begin
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
                                            call_sub_r   <= 6'd0;
                                            call_phase_r <= 4'd7;
                                        end else begin
                                            container_idx_r <= container_idx_r + 7'd1;
                                            call_sub_r <= 6'd1;
                                        end
                                    end
                                    default: ;
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

                        default: ;
                    endcase
                end
