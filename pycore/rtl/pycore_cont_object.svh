// pycore_cont_object.svh — name/global/RF helper arms of S_CONTAINER.
// Attribute protocol (LOAD/STORE/DELETE_ATTR) lands here in M2.
// Included inside pycore_core's unique case (container_op_r). Do not compile alone.
                        CONT_LOAD_CONST: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if ({32'b0, cur_arg_r} >= consts_base_r[127:64]) begin
                                        container_mem_fault_r <= 1'b1;
                                    end else begin
                                        container_dmem_addr_r <= pycore_tuple_val_addr(
                                            consts_base_r[31:0], cur_arg_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_VAL;
                                    end
                                end

                                CP_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <= pycore_tuple_tag_addr(
                                            consts_base_r[31:0], cur_arg_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_TAG;
                                    end
                                end

                                CP_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'({2'b0, tos_r});
                                        container_wb_data_r <= pycore_make_entry(
                                            container_rd_data_r[3:0],
                                            container_val_r);
                                        tos_r             <= tos_r + RF_AW'(1);
                                        fetch_skip_r      <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_LOAD_CONST

                        CONT_LOAD_GLOBAL: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    // namei: LOAD_GLOBAL uses arg>>1; LOAD_NAME
                                    // uses raw arg — the push_null flag was
                                    // sampled in S_EXEC and mirrors this shift.
                                    begin
                                        logic [31:0] namei;
                                        namei = container_push_null_r ?
                                                (cur_arg_r >> 1) : cur_arg_r;
                                        if ({32'b0, namei} >= names_base_r[127:64]) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_dmem_addr_r <= pycore_tuple_val_addr(
                                                names_base_r[31:0], namei);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            // Stash namei for CP_NAME_TAG.
                                            container_idx_r <= namei[6:0];
                                            container_phase_r <= CP_NAME_VAL;
                                        end
                                    end
                                end

                                CP_NAME_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <= pycore_tuple_tag_addr(
                                            names_base_r[31:0], {25'b0, container_idx_r});
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_NAME_TAG;
                                    end
                                end

                                CP_NAME_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        // Key ready in {container_rd_data_r[3:0],
                                        // container_val_r} — build search key
                                        // and start probing globals dict header.
                                        container_tag_r <= container_rd_data_r[3:0];
                                        // container_val_r already holds VAL.
                                        if (!pycore_dict_key_tag_ok(container_rd_data_r[3:0])) begin
                                            container_type_trap_r <= 1'b1;
                                        end else begin
                                            container_base_r         <= globals_base_r;
                                            container_dmem_addr_r    <= globals_base_r;
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_HDR;
                                        end
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        container_slot_count_r <= cont_dict_hdr_slots[31:0];
                                        container_used_r       <= cont_dict_hdr_used;
                                        container_dmem_addr_r <=
                                            pycore_dict_table_ptr_addr(container_base_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_LIST_BUF;
                                    end
                                end

                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        container_buf_r <= cont_dict_table_ptr;
                                        if ((container_slot_count_r == 32'd0) ||
                                            (cont_dict_table_ptr == 32'd0)) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            begin
                                                logic [31:0] probe0;
                                                probe0 = pycore_dict_key_hash(
                                                    container_tag_r, container_val_r)
                                                    & (container_slot_count_r - 32'd1);
                                                container_probe_r   <= probe0;
                                                container_probe_n_r <= 32'd0;
                                                container_dmem_addr_r <=
                                                    pycore_dict_ktag_addr(
                                                        cont_dict_table_ptr, probe0);
                                            end
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_PROBE;
                                        end
                                    end
                                end

                                CP_DICT_PROBE: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_probe_n_r >= container_slot_count_r) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_probe_n_r <= container_probe_n_r + 32'd1;
                                            if (container_rd_data_r[3:0] == PY_TAG_UNINIT) begin
                                                // Name not found — NameError analog.
                                                container_mem_fault_r <= 1'b1;
                                            end else if (pycore_dict_tombstone(
                                                            container_rd_data_r[3:0])) begin
                                                if (container_probe_n_r + 32'd1
                                                        >= container_slot_count_r) begin
                                                    container_mem_fault_r <= 1'b1;
                                                end else begin
                                                    container_probe_r <= cont_probe_next;
                                                    container_dmem_addr_r <=
                                                        pycore_dict_ktag_addr(
                                                            container_buf_r, cont_probe_next);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                end
                                            end else begin
                                                // Occupied: rich_eq (incl. cross-tag numeric) at CHK_VAL.
                                                container_probe_tag_r    <= container_rd_data_r[3:0];
                                                container_dmem_addr_r    <= pycore_dict_kval_addr(
                                                    container_buf_r, container_probe_r);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r        <= CP_DICT_CHK_VAL;
                                            end
                                        end
                                    end
                                end

                                CP_DICT_CHK_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_dict_key_match) begin
                                            container_dmem_addr_r <= pycore_dict_vval_addr(
                                                container_buf_r, container_probe_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_RD_VVAL;
                                        end else if (container_probe_n_r
                                                     >= container_slot_count_r) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_probe_r <= cont_probe_next;
                                            container_dmem_addr_r <= pycore_dict_ktag_addr(
                                                container_buf_r, cont_probe_next);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_PROBE;
                                        end
                                    end
                                end

                                CP_DICT_RD_VVAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <= pycore_dict_vtag_addr(
                                            container_buf_r, container_probe_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_RD_VTAG;
                                    end
                                end

                                CP_DICT_RD_VTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        // Push value at TOS.
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'({2'b0, tos_r});
                                        container_wb_data_r <= pycore_make_entry(
                                            container_rd_data_r[3:0],
                                            container_val_r);
                                        tos_r <= tos_r + RF_AW'(1);
                                        if (container_push_null_r) begin
                                            // Second beat: push NULL next cycle.
                                            container_phase_r <= CP_LG_WB_NULL;
                                        end else begin
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end
                                    end
                                end

                                CP_LG_WB_NULL: begin
                                    container_wb_we_r   <= 1'b1;
                                    container_wb_addr_r <= RF_AW'({2'b0, tos_r});
                                    container_wb_data_r <= pycore_make_entry(PY_TAG_NULL, '0);
                                    tos_r <= tos_r + RF_AW'(1);
                                    fetch_skip_r      <= 1'b1;
                                    container_phase_r <= CP_DONE;
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_LOAD_GLOBAL

                        CONT_STORE_NAME: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if ({32'b0, cur_arg_r} >= names_base_r[127:64]) begin
                                        container_mem_fault_r <= 1'b1;
                                    end else begin
                                        container_dmem_addr_r <= pycore_tuple_val_addr(
                                            names_base_r[31:0], cur_arg_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_idx_r          <= cur_arg_r[6:0];
                                        container_phase_r        <= CP_NAME_VAL;
                                    end
                                end

                                CP_NAME_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <= pycore_tuple_tag_addr(
                                            names_base_r[31:0], {25'b0, container_idx_r});
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_NAME_TAG;
                                    end
                                end

                                CP_NAME_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_tag_r <= container_rd_data_r[3:0];
                                        if (!pycore_dict_key_tag_ok(container_rd_data_r[3:0])) begin
                                            container_type_trap_r <= 1'b1;
                                        end else begin
                                            // Value @ RF[tos-1] — set RF addr early for
                                            // grow marshal entry2.
                                            container_rf_addr_r      <= RF_AW'(tos_r - RF_AW'(1));
                                            container_val_rf_addr_r  <= RF_AW'(tos_r - RF_AW'(1));
                                            container_insert_new_r   <= 1'b0;
                                            container_finishing_r    <= 1'b0;
                                            container_tomb_valid_r   <= 1'b0;
                                            container_tomb_idx_r     <= 32'd0;
                                            container_base_r         <= globals_base_r;
                                            container_dmem_addr_r    <= globals_base_r;
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_HDR;
                                        end
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_finishing_r) begin
                                            container_finishing_r <= 1'b0;
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            container_slot_count_r <= cont_dict_hdr_slots[31:0];
                                            container_used_r       <= cont_dict_hdr_used;
                                            container_dmem_addr_r <=
                                                pycore_dict_table_ptr_addr(container_base_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_LIST_BUF;
                                        end
                                    end
                                end

                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        container_buf_r <= cont_dict_table_ptr;
                                        if ((container_slot_count_r == 32'd0) ||
                                            (cont_dict_table_ptr == 32'd0)) begin
                                            if (EXCORE_EN &&
                                                pycore_trap_recoverable(PY_TRAP_DICT_GROW)) begin
                                                trap_marshal_pending_r     <= 1'b1;
                                                trap_marshal_code_r        <= PY_TRAP_DICT_GROW;
                                                trap_marshal_entry_count_r <= 3'd3;
                                                trap_marshal_entries_r[0]  <=
                                                    pycore_make_entry(
                                                        PY_TAG_DICT,
                                                        {{96{1'b0}}, container_base_r});
                                                trap_marshal_entries_r[1]  <=
                                                    pycore_make_entry(
                                                        container_tag_r, container_val_r);
                                                trap_marshal_entries_r[2]  <=
                                                    pycore_make_entry(
                                                        cont_rf_rs1_tag, cont_rf_rs1_val);
                                                container_phase_r          <= CP_DONE;
                                            end else begin
                                                container_dict_grow_trap_r <= 1'b1;
                                            end
                                        end else begin
                                            begin
                                                logic [31:0] probe0;
                                                probe0 = pycore_dict_key_hash(
                                                    container_tag_r, container_val_r)
                                                    & (container_slot_count_r - 32'd1);
                                                container_probe_r   <= probe0;
                                                container_probe_n_r <= 32'd0;
                                                container_dmem_addr_r <=
                                                    pycore_dict_ktag_addr(
                                                        cont_dict_table_ptr, probe0);
                                            end
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_PROBE;
                                        end
                                    end
                                end

                                CP_DICT_PROBE: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_probe_n_r >= container_slot_count_r) begin
                                            if (container_tomb_valid_r) begin
                                                if (cont_dict_needs_grow) begin
                                                    if (EXCORE_EN &&
                                                        pycore_trap_recoverable(
                                                            PY_TRAP_DICT_GROW)) begin
                                                        trap_marshal_pending_r     <= 1'b1;
                                                        trap_marshal_code_r        <=
                                                            PY_TRAP_DICT_GROW;
                                                        trap_marshal_entry_count_r <= 3'd3;
                                                        trap_marshal_entries_r[0]  <=
                                                            pycore_make_entry(
                                                                PY_TAG_DICT,
                                                                {{96{1'b0}},
                                                                 container_base_r});
                                                        trap_marshal_entries_r[1]  <=
                                                            pycore_make_entry(
                                                                container_tag_r,
                                                                container_val_r);
                                                        trap_marshal_entries_r[2]  <=
                                                            pycore_make_entry(
                                                                cont_rf_rs1_tag,
                                                                cont_rf_rs1_val);
                                                        container_phase_r          <= CP_DONE;
                                                    end else begin
                                                        container_dict_grow_trap_r <= 1'b1;
                                                    end
                                                end else begin
                                                    container_probe_r      <=
                                                        container_tomb_idx_r;
                                                    container_insert_new_r <= 1'b1;
                                                    container_dmem_addr_r  <=
                                                        pycore_dict_kval_addr(
                                                            container_buf_r,
                                                            container_tomb_idx_r);
                                                    container_dmem_we_r    <= 1'b1;
                                                    container_dmem_wdata_r <= container_val_r;
                                                    container_dmem_pending_r <= 1'b1;
                                                    container_phase_r <= CP_DICT_WR_KVAL;
                                                end
                                            end else begin
                                                if (EXCORE_EN &&
                                                    pycore_trap_recoverable(
                                                        PY_TRAP_DICT_GROW)) begin
                                                    trap_marshal_pending_r     <= 1'b1;
                                                    trap_marshal_code_r        <=
                                                        PY_TRAP_DICT_GROW;
                                                    trap_marshal_entry_count_r <= 3'd3;
                                                    trap_marshal_entries_r[0]  <=
                                                        pycore_make_entry(
                                                            PY_TAG_DICT,
                                                            {{96{1'b0}}, container_base_r});
                                                    trap_marshal_entries_r[1]  <=
                                                        pycore_make_entry(
                                                            container_tag_r, container_val_r);
                                                    trap_marshal_entries_r[2]  <=
                                                        pycore_make_entry(
                                                            cont_rf_rs1_tag, cont_rf_rs1_val);
                                                    container_phase_r          <= CP_DONE;
                                                end else begin
                                                    container_dict_grow_trap_r <= 1'b1;
                                                end
                                            end
                                        end else begin
                                            container_probe_n_r <= container_probe_n_r + 32'd1;
                                            if (container_rd_data_r[3:0] == PY_TAG_UNINIT) begin
                                                if (cont_dict_needs_grow) begin
                                                    if (EXCORE_EN &&
                                                        pycore_trap_recoverable(
                                                            PY_TRAP_DICT_GROW)) begin
                                                        trap_marshal_pending_r     <= 1'b1;
                                                        trap_marshal_code_r        <=
                                                            PY_TRAP_DICT_GROW;
                                                        trap_marshal_entry_count_r <= 3'd3;
                                                        trap_marshal_entries_r[0]  <=
                                                            pycore_make_entry(
                                                                PY_TAG_DICT,
                                                                {{96{1'b0}},
                                                                 container_base_r});
                                                        trap_marshal_entries_r[1]  <=
                                                            pycore_make_entry(
                                                                container_tag_r,
                                                                container_val_r);
                                                        trap_marshal_entries_r[2]  <=
                                                            pycore_make_entry(
                                                                cont_rf_rs1_tag,
                                                                cont_rf_rs1_val);
                                                        container_phase_r          <= CP_DONE;
                                                    end else begin
                                                        container_dict_grow_trap_r <= 1'b1;
                                                    end
                                                end else begin
                                                    begin
                                                        logic [31:0] ins;
                                                        ins = container_tomb_valid_r ?
                                                              container_tomb_idx_r :
                                                              container_probe_r;
                                                        container_probe_r      <= ins;
                                                        container_insert_new_r <= 1'b1;
                                                        container_dmem_addr_r  <=
                                                            pycore_dict_kval_addr(
                                                                container_buf_r, ins);
                                                        container_dmem_we_r    <= 1'b1;
                                                        container_dmem_wdata_r <=
                                                            container_val_r;
                                                        container_dmem_pending_r <= 1'b1;
                                                        container_phase_r <= CP_DICT_WR_KVAL;
                                                    end
                                                end
                                            end else if (pycore_dict_tombstone(
                                                            container_rd_data_r[3:0])) begin
                                                if (!container_tomb_valid_r) begin
                                                    container_tomb_valid_r <= 1'b1;
                                                    container_tomb_idx_r   <=
                                                        container_probe_r;
                                                end
                                                if (container_probe_n_r + 32'd1
                                                        >= container_slot_count_r) begin
                                                    container_probe_n_r <=
                                                        container_slot_count_r;
                                                end else begin
                                                    container_probe_r <= cont_probe_next;
                                                    container_dmem_addr_r <=
                                                        pycore_dict_ktag_addr(
                                                            container_buf_r, cont_probe_next);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                end
                                            end else begin
                                                // Occupied: rich_eq (incl. cross-tag numeric) at CHK_VAL.
                                                container_probe_tag_r    <= container_rd_data_r[3:0];
                                                container_dmem_addr_r    <= pycore_dict_kval_addr(
                                                    container_buf_r, container_probe_r);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r        <= CP_DICT_CHK_VAL;
                                            end
                                        end
                                    end
                                end

                                CP_DICT_CHK_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_dict_key_match) begin
                                            container_insert_new_r <= 1'b0;
                                            container_dmem_addr_r  <= pycore_dict_kval_addr(
                                                container_buf_r, container_probe_r);
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <= container_val_r;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_WR_KVAL;
                                        end else if (container_probe_n_r
                                                     >= container_slot_count_r) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_probe_r <= cont_probe_next;
                                            container_dmem_addr_r <= pycore_dict_ktag_addr(
                                                container_buf_r, cont_probe_next);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_PROBE;
                                        end
                                    end
                                end

                                CP_DICT_WR_KVAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_dict_ktag_addr(
                                            container_buf_r, container_probe_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_WR_KTAG;
                                    end
                                end

                                CP_DICT_WR_KTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_rf_addr_r <= container_val_rf_addr_r;
                                        container_phase_r   <= CP_DICT_RD_VAL;
                                    end
                                end

                                CP_DICT_RD_VAL: begin
                                    container_dmem_addr_r  <= pycore_dict_vval_addr(
                                        container_buf_r, container_probe_r);
                                    container_dmem_we_r    <= 1'b1;
                                    container_dmem_wdata_r <= cont_rf_rs1_val;
                                    container_dmem_pending_r <= 1'b1;
                                    container_lfb_lo_r <= cont_rf_rs1_tag;
                                    container_phase_r <= CP_DICT_WR_VVAL;
                                end

                                CP_DICT_WR_VVAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_dict_vtag_addr(
                                            container_buf_r, container_probe_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, container_lfb_lo_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_WR_VTAG;
                                    end
                                end

                                CP_DICT_WR_VTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_insert_new_r) begin
                                            container_dmem_addr_r  <= container_base_r;
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <= pycore_dict_header(
                                                {32'b0, container_slot_count_r},
                                                container_used_r + 64'd1);
                                            container_dmem_pending_r <= 1'b1;
                                            container_used_r       <= container_used_r + 64'd1;
                                            container_insert_new_r <= 1'b0;
                                            container_finishing_r  <= 1'b1;
                                            container_phase_r <= CP_HDR;
                                        end else begin
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_STORE_NAME

                        CONT_LFB_PAIR: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    container_rf_addr_r <= RF_AW'(
                                        {2'b0, cur_locals_base_r} + {5'b0, container_lfb_hi_r});
                                    container_phase_r <= CP_LFB_FIRST;
                                end

                                CP_LFB_FIRST: begin
                                    container_wb_we_r   <= 1'b1;
                                    container_wb_addr_r <= RF_AW'({2'b0, tos_r});
                                    container_wb_data_r <= rf_rs1;
                                    tos_r <= tos_r + RF_AW'(1);
                                    container_rf_addr_r <= RF_AW'(
                                        {2'b0, cur_locals_base_r} + {5'b0, container_lfb_lo_r});
                                    container_phase_r <= CP_LFB_SECOND;
                                end

                                CP_LFB_SECOND: begin
                                    container_wb_we_r   <= 1'b1;
                                    container_wb_addr_r <= RF_AW'({2'b0, tos_r});
                                    container_wb_data_r <= rf_rs1;
                                    tos_r <= tos_r + RF_AW'(1);
                                    fetch_skip_r      <= 1'b1;
                                    container_phase_r <= CP_DONE;
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_LFB_PAIR

                        CONT_SWAP: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    container_wb_we_r   <= 1'b1;
                                    container_wb_addr_r <= RF_AW'(
                                        {2'b0, tos_r} - 9'd1);
                                    container_wb_data_r <= rs2_r;
                                    container_phase_r   <= CP_LFB_FIRST;
                                end

                                CP_LFB_FIRST: begin
                                    container_wb_we_r   <= 1'b1;
                                    container_wb_addr_r <= RF_AW'(
                                        {2'b0, tos_r} - {2'b0, cur_arg_r[6:0]});
                                    container_wb_data_r <= rs1_r;
                                    fetch_skip_r        <= 1'b1;
                                    container_phase_r   <= CP_DONE;
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_SWAP

                        CONT_SFLF: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    container_wb_we_r   <= 1'b1;
                                    container_wb_addr_r <= RF_AW'(
                                        {2'b0, cur_locals_base_r} +
                                        {5'b0, container_lfb_hi_r});
                                    container_wb_data_r <= rs1_r;
                                    tos_r <= tos_r - RF_AW'(1);
                                    container_rf_addr_r <= RF_AW'(
                                        {2'b0, cur_locals_base_r} +
                                        {5'b0, container_lfb_lo_r});
                                    container_phase_r <= CP_LFB_FIRST;
                                end

                                CP_LFB_FIRST: begin
                                    // hi==lo: RF write from CP_INIT is not yet
                                    // visible on rf_rs1; bypass the stored TOS.
                                    container_wb_we_r   <= 1'b1;
                                    container_wb_addr_r <= RF_AW'({2'b0, tos_r});
                                    container_wb_data_r <=
                                        (container_lfb_hi_r == container_lfb_lo_r)
                                            ? rs1_r : rf_rs1;
                                    tos_r <= tos_r + RF_AW'(1);
                                    fetch_skip_r      <= 1'b1;
                                    container_phase_r <= CP_DONE;
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_SFLF

                        CONT_SFSF: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    container_wb_we_r   <= 1'b1;
                                    container_wb_addr_r <= RF_AW'(
                                        {2'b0, cur_locals_base_r} +
                                        {5'b0, container_lfb_hi_r});
                                    container_wb_data_r <= rs1_r;
                                    // Point rs1 at the second-from-top (old
                                    // tos_r-2) for the next-cycle store.
                                    container_rf_addr_r <= RF_AW'(
                                        {2'b0, tos_r} - 9'd2);
                                    tos_r <= tos_r - RF_AW'(1);
                                    container_phase_r <= CP_LFB_FIRST;
                                end

                                CP_LFB_FIRST: begin
                                    container_wb_we_r   <= 1'b1;
                                    container_wb_addr_r <= RF_AW'(
                                        {2'b0, cur_locals_base_r} +
                                        {5'b0, container_lfb_lo_r});
                                    container_wb_data_r <= rf_rs1;
                                    tos_r <= tos_r - RF_AW'(1);
                                    fetch_skip_r      <= 1'b1;
                                    container_phase_r <= CP_DONE;
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_SFSF

                        CONT_LFAC: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    container_wb_we_r   <= 1'b1;
                                    container_wb_addr_r <= RF_AW'({2'b0, tos_r});
                                    container_wb_data_r <= rs1_r;
                                    tos_r <= tos_r + RF_AW'(1);
                                    container_phase_r <= CP_LFB_FIRST;
                                end

                                CP_LFB_FIRST: begin
                                    container_wb_we_r   <= 1'b1;
                                    container_wb_addr_r <= RF_AW'(
                                        {2'b0, cur_locals_base_r} +
                                        {5'b0, cur_arg_r[7:0]});
                                    container_wb_data_r <=
                                        pycore_make_entry(PY_TAG_UNINIT, '0);
                                    fetch_skip_r      <= 1'b1;
                                    container_phase_r <= CP_DONE;
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_LFAC

