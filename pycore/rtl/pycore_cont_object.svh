// pycore_cont_object.svh — name/global/RF helper + attribute protocol arms.
// LOAD/STORE/DELETE_ATTR (CONT_LOAD_ATTR / STORE_ATTR / DELETE_ATTR).
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

                        CONT_TO_BOOL: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    begin
                                        logic truthy;
                                        truthy = 1'b0;
                                        if (pycore_is_none(cont_rs1_tag, cont_rs1_val)) begin
                                            truthy = 1'b0;
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(1));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}}, truthy});
                                            fetch_skip_r <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else if (cont_rs1_tag == PY_TAG_INT) begin
                                            truthy = (cont_rs1_val != {PYCORE_VAL_WIDTH{1'b0}});
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(1));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}}, truthy});
                                            fetch_skip_r <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else if (cont_rs1_tag == PY_TAG_BOOL) begin
                                            truthy = cont_rs1_val[0];
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(1));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}}, truthy});
                                            fetch_skip_r <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else if (cont_rs1_tag == PY_TAG_FLOAT) begin
                                            truthy = (cont_rs1_val[62:0] != 63'b0);
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(1));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}}, truthy});
                                            fetch_skip_r <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else if (cont_rs1_tag == PY_TAG_SHORT_STR) begin
                                            if (pycore_short_str_size(cont_rs1_val) >
                                                    PYCORE_SHORT_STR_MAX_BYTES) begin
                                                container_type_trap_r <= 1'b1;
                                            end else begin
                                                truthy = (pycore_short_str_size(cont_rs1_val) != 4'b0);
                                                container_wb_we_r   <= 1'b1;
                                                container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(1));
                                                container_wb_data_r <= pycore_make_entry(
                                                    PY_TAG_BOOL,
                                                    {{(PYCORE_VAL_WIDTH-1){1'b0}}, truthy});
                                                fetch_skip_r <= 1'b1;
                                                container_phase_r <= CP_DONE;
                                            end
                                        end else if (cont_rs1_tag == PY_TAG_LONG_STR) begin
                                            truthy = (pycore_long_str_size(cont_rs1_val) != 64'b0);
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(1));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}}, truthy});
                                            fetch_skip_r <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else if (cont_rs1_tag == PY_TAG_TUPLE) begin
                                            truthy = (pycore_tuple_size(cont_rs1_val) != 64'b0);
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(1));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}}, truthy});
                                            fetch_skip_r <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else if (cont_rs1_tag == PY_TAG_RANGE) begin
                                            if (pycore_range_is_tuple_mode(cont_rs1_val) ||
                                                cont_rs1_val[31:0] == 32'b0) begin
                                                container_type_trap_r <= 1'b1;
                                            end else begin
                                                truthy = (pycore_range_inline_len(cont_rs1_val) != 64'd0);
                                                container_wb_we_r   <= 1'b1;
                                                container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(1));
                                                container_wb_data_r <= pycore_make_entry(
                                                    PY_TAG_BOOL,
                                                    {{(PYCORE_VAL_WIDTH-1){1'b0}}, truthy});
                                                fetch_skip_r <= 1'b1;
                                                container_phase_r <= CP_DONE;
                                            end
                                        end else if (pycore_is_list(cont_rs1_tag, cont_rs1_val) ||
                                                     pycore_is_dict(cont_rs1_tag, cont_rs1_val) ||
                                                     pycore_is_set(cont_rs1_tag, cont_rs1_val)) begin
                                            container_base_r         <= cont_rs1_addr;
                                            container_dmem_addr_r    <= cont_rs1_addr;
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_HDR;
                                        end else begin
                                            container_type_trap_r <= 1'b1;
                                        end
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        if (pycore_is_list(cont_rs1_tag, cont_rs1_val)) begin
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                 (cont_hdr_len != 64'd0)});
                                        end else begin
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                 (cont_dict_hdr_used != 64'd0)});
                                        end
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(1));
                                        fetch_skip_r <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_TO_BOOL

                        CONT_LOAD_GLOBAL: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    // namei: LOAD_GLOBAL always uses arg>>1
                                    // (null_bit = arg&1 is orthogonal — it only
                                    // controls the post-load NULL push via
                                    // container_push_null_r).  LOAD_NAME uses
                                    // the raw arg.  Do NOT gate the shift on
                                    // push_null_r: LOAD_GLOBAL with null_bit=0
                                    // and namei>=1 (arg>=2) would then probe
                                    // co_names[arg] and raise a false MEM_FAULT.
                                    begin
                                        logic [31:0] namei;
                                        namei = (cur_opcode_r == PY_OP_LOAD_GLOBAL) ?
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
                                            container_lfb_lo_r[1]    <= 1'b0; // builtins-tried
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
                                            if (!container_lfb_lo_r[1] &&
                                                (builtins_base_r != 32'd0)) begin
                                                container_lfb_lo_r[1]    <= 1'b1;
                                                container_base_r         <= builtins_base_r;
                                                container_tomb_valid_r   <= 1'b0;
                                                container_dmem_addr_r    <= builtins_base_r;
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r        <= CP_HDR;
                                            end else begin
                                                container_mem_fault_r <= 1'b1;
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
                                            if (!container_lfb_lo_r[1] &&
                                                (builtins_base_r != 32'd0)) begin
                                                container_lfb_lo_r[1]    <= 1'b1;
                                                container_base_r         <= builtins_base_r;
                                                container_tomb_valid_r   <= 1'b0;
                                                container_dmem_addr_r    <= builtins_base_r;
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r        <= CP_HDR;
                                            end else begin
                                                container_mem_fault_r <= 1'b1;
                                            end
                                        end else begin
                                            container_probe_n_r <= container_probe_n_r + 32'd1;
                                            if (pycore_dict_slot_empty(
                                                    container_rd_data_r)) begin
                                                // Name not found — try builtins once.
                                                if (!container_lfb_lo_r[1] &&
                                                    (builtins_base_r != 32'd0)) begin
                                                    container_lfb_lo_r[1]    <= 1'b1;
                                                    container_base_r         <= builtins_base_r;
                                                    container_tomb_valid_r   <= 1'b0;
                                                    container_dmem_addr_r    <= builtins_base_r;
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                    container_phase_r        <= CP_HDR;
                                                end else begin
                                                    container_mem_fault_r <= 1'b1;
                                                end
                                            end else if (pycore_dict_tombstone(
                                                            container_rd_data_r[3:0])) begin
                                                if (container_probe_n_r + 32'd1
                                                        >= container_slot_count_r) begin
                                                    if (!container_lfb_lo_r[1] &&
                                                        (builtins_base_r != 32'd0)) begin
                                                        container_lfb_lo_r[1]    <= 1'b1;
                                                        container_base_r         <= builtins_base_r;
                                                        container_tomb_valid_r   <= 1'b0;
                                                        container_dmem_addr_r    <= builtins_base_r;
                                                        container_dmem_we_r      <= 1'b0;
                                                        container_dmem_pending_r <= 1'b1;
                                                        container_phase_r        <= CP_HDR;
                                                    end else begin
                                                        container_mem_fault_r <= 1'b1;
                                                    end
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
                                            if (!container_lfb_lo_r[1] &&
                                                (builtins_base_r != 32'd0)) begin
                                                container_lfb_lo_r[1]    <= 1'b1;
                                                container_base_r         <= builtins_base_r;
                                                container_tomb_valid_r   <= 1'b0;
                                                container_dmem_addr_r    <= builtins_base_r;
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r        <= CP_HDR;
                                            end else begin
                                                container_mem_fault_r <= 1'b1;
                                            end
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
                                    container_wb_data_r <=
                                        pycore_make_control(PY_CTL_NULL);
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
                                        container_order_key_tag_r <=
                                            container_rd_data_r[3:0];
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
                                            container_dmem_addr_r <=
                                                pycore_dict_meta_addr(container_base_r);
                                            container_dmem_we_r <= 1'b1;
                                            container_dmem_wdata_r <= pycore_dict_meta(
                                                container_dict_version_r,
                                                container_order_len_r);
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_META_FINAL;
                                        end else begin
                                            container_slot_count_r <= cont_dict_hdr_slots[31:0];
                                            container_used_r       <= cont_dict_hdr_used;
                                            container_dmem_addr_r <=
                                                pycore_dict_meta_addr(container_base_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_DICT_META;
                                        end
                                    end
                                end

                                CP_DICT_META: begin
                                    if (!container_dmem_pending_r) begin
                                        container_order_len_r <=
                                            pycore_dict_order_len_from_meta(
                                                container_rd_data_r);
                                        container_dict_version_r <=
                                            pycore_dict_version_from_meta(
                                                container_rd_data_r);
                                        container_dmem_addr_r <=
                                            pycore_dict_table_ptr_addr(container_base_r);
                                        container_dmem_we_r <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_LIST_BUF;
                                    end
                                end

                                CP_DICT_META_FINAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_finishing_r <= 1'b0;
                                        tos_r <= tos_r - RF_AW'(1);
                                        fetch_skip_r <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end
                                end

                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        container_buf_r <= cont_dict_table_ptr;
                                        container_order_ptr_r <= cont_dict_order_ptr;
                                        if ((container_slot_count_r == 32'd0) ||
                                            (cont_dict_table_ptr == 32'd0)) begin
                                            if (EXCORE_EN &&
                                                pycore_trap_recoverable(PY_TRAP_DICT_GROW)) begin
                                                trap_marshal_pending_r     <= 1'b1;
                                                trap_marshal_code_r        <= PY_TRAP_DICT_GROW;
                                                trap_marshal_entry_count_r <= 3'd3;
                                                trap_marshal_entries_r[0]  <=
                                                    pycore_make_mut(
                                                        PY_MUT_DICT,
                                                        {32'b0, container_base_r}, 1'b0);
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
                                                            pycore_make_mut(
                                                                PY_MUT_DICT,
                                                                {32'b0,
                                                                 container_base_r}, 1'b0);
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
                                                        pycore_make_mut(
                                                            PY_MUT_DICT,
                                                            {32'b0,
                                                             container_base_r}, 1'b0);
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
                                            if (pycore_dict_slot_empty(
                                                    container_rd_data_r)) begin
                                                if (cont_dict_needs_grow) begin
                                                    if (EXCORE_EN &&
                                                        pycore_trap_recoverable(
                                                            PY_TRAP_DICT_GROW)) begin
                                                        trap_marshal_pending_r     <= 1'b1;
                                                        trap_marshal_code_r        <=
                                                            PY_TRAP_DICT_GROW;
                                                        trap_marshal_entry_count_r <= 3'd3;
                                                        trap_marshal_entries_r[0]  <=
                                                            pycore_make_mut(
                                                                PY_MUT_DICT,
                                                                {32'b0,
                                                                 container_base_r}, 1'b0);
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
                                        container_dmem_wdata_r <=
                                            pycore_dict_key_tag_word(
                                                container_tag_r, container_val_r);
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
                                            container_dmem_addr_r <=
                                                pycore_dict_order_val_addr(
                                                    container_order_ptr_r,
                                                    container_order_len_r[31:0]);
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <= container_val_r;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_ORDER_VAL;
                                        end else begin
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end
                                    end
                                end

                                CP_DICT_ORDER_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r <=
                                            pycore_dict_order_tag_addr(
                                                container_order_ptr_r,
                                                container_order_len_r[31:0]);
                                        container_dmem_we_r <= 1'b1;
                                        container_dmem_wdata_r <=
                                            {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_ORDER_TAG;
                                    end
                                end

                                CP_DICT_ORDER_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_used_r <= container_used_r + 64'd1;
                                        container_order_len_r <=
                                            container_order_len_r + 64'd1;
                                        container_dict_version_r <=
                                            container_dict_version_r + 64'd1;
                                        container_insert_new_r <= 1'b0;
                                        container_dmem_addr_r <= container_base_r;
                                        container_dmem_we_r <= 1'b1;
                                        container_dmem_wdata_r <= pycore_dict_header(
                                            {32'b0, container_slot_count_r},
                                            container_used_r + 64'd1);
                                        container_dmem_pending_r <= 1'b1;
                                        container_finishing_r <= 1'b1;
                                        container_phase_r <= CP_HDR;
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

                        // =====================================================
                        // LOAD_ATTR — instance __dict__ then MRO tp_dict walk.
                        // Overlay: push_null=method_flag, src_len=type addr,
                        // count=MRO depth, lfb_hi=source (0=INSTANCE,1=TYPE),
                        // lfb_lo[0]=in_type_walk, lfb_lo[1]=dunder field return
                        //   (__dict__ via IDICT, __base__ via CP_VAL/CP_TAG),
                        // lfb_lo[2]=staticmethod unwrap / skip OBJECT unwrap,
                        // src_buf=receiver addr,
                        // tag/val=name key during probe / attr value on hit.
                        // Special SHORT_STR names before probe:
                        //   __dict__  → field0 MUT_DICT handle (INSTANCE/TYPE)
                        //   __class__ → ob_type (INSTANCE) or self (TYPE)
                        //   __base__  → field1 tp_base or None (TYPE only)
                        // =====================================================
                        CONT_LOAD_ATTR: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    begin
                                        logic [31:0] namei;
                                        namei = cur_arg_r >> 1;
                                        if ({32'b0, namei} >= names_base_r[127:64]) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_dmem_addr_r <= pycore_tuple_val_addr(
                                                names_base_r[31:0], namei);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_idx_r          <= namei[6:0];
                                            container_phase_r        <= CP_NAME_VAL;
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
                                        container_tag_r <= container_rd_data_r[3:0];
                                        if (!pycore_dict_key_tag_ok(container_rd_data_r[3:0])) begin
                                            container_type_trap_r <= 1'b1;
                                        end else if (cont_rs1_tag != PY_TAG_OBJECT) begin
                                            container_type_trap_r <= 1'b1;
                                        end else begin
                                            container_src_buf_r      <= cont_rs1_addr;
                                            container_finishing_r    <= 1'b0;
                                            container_dmem_addr_r    <= cont_rs1_addr;
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_ATTR_HEAD;
                                        end
                                    end
                                end

                                CP_ATTR_HEAD: begin
                                    if (!container_dmem_pending_r) begin
                                        begin
                                            logic [63:0] attr_ob_type;
                                            logic [31:0] attr_ob_kind;
                                            logic        name_is_dict;
                                            logic        name_is_class;
                                            logic        name_is_base;
                                            attr_ob_type = pycore_ob_type(container_rd_data_r);
                                            attr_ob_kind = pycore_ob_kind(container_rd_data_r);
                                            name_is_dict = pycore_attr_name_is_dict(
                                                container_tag_r, container_val_r);
                                            name_is_class = pycore_attr_name_is_class(
                                                container_tag_r, container_val_r);
                                            name_is_base = pycore_attr_name_is_base(
                                                container_tag_r, container_val_r);
                                            if (attr_ob_kind == PY_OBK_INSTANCE) begin
                                                if (name_is_dict) begin
                                                    // Return field0 dict handle (no probe).
                                                    container_src_len_r     <= attr_ob_type[31:0];
                                                    container_count_r       <= 7'd0;
                                                    container_lfb_hi_r      <= 4'd0;
                                                    container_lfb_lo_r      <= 4'b0010; // [1]
                                                    container_finishing_r   <= 1'b0;
                                                    container_dmem_addr_r <=
                                                        pycore_obj_field_val_addr(
                                                            container_src_buf_r, 32'd0);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                    container_phase_r        <= CP_ATTR_IDICT;
                                                end else if (name_is_class) begin
                                                    if (attr_ob_type == 64'd0) begin
                                                        container_type_trap_r <= 1'b1;
                                                    end else begin
                                                        container_tag_r        <= PY_TAG_OBJECT;
                                                        container_val_r        <=
                                                            {64'd0, attr_ob_type};
                                                        container_push_null_r  <= 1'b0;
                                                        container_lfb_hi_r     <= 4'd0;
                                                        container_lfb_lo_r     <= 4'b0100; // [2]
                                                        container_phase_r      <= CP_ATTR_WB;
                                                    end
                                                end else begin
                                                    container_src_len_r     <= attr_ob_type[31:0];
                                                    container_count_r       <= 7'd0;
                                                    container_lfb_hi_r      <= 4'd0; // INSTANCE
                                                    container_lfb_lo_r      <= 4'd0; // not type-walk
                                                    container_finishing_r   <= 1'b0;
                                                    container_dmem_addr_r <=
                                                        pycore_obj_field_val_addr(
                                                            container_src_buf_r, 32'd0);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                    container_phase_r        <= CP_ATTR_IDICT;
                                                end
                                            end else if (attr_ob_kind == PY_OBK_TYPE) begin
                                                if (name_is_dict) begin
                                                    // Return tp_dict handle (field0).
                                                    container_src_len_r     <= container_src_buf_r;
                                                    container_count_r       <= 7'd0;
                                                    container_lfb_hi_r      <= 4'd1;
                                                    container_lfb_lo_r      <= 4'b0010; // [1]
                                                    container_finishing_r   <= 1'b0;
                                                    container_dmem_addr_r <=
                                                        pycore_obj_field_val_addr(
                                                            container_src_buf_r, 32'd0);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                    container_phase_r        <= CP_ATTR_IDICT;
                                                end else if (name_is_class) begin
                                                    // Type.__class__ → self (identity).
                                                    container_tag_r       <= PY_TAG_OBJECT;
                                                    container_val_r       <=
                                                        {96'd0, container_src_buf_r};
                                                    container_push_null_r <= 1'b0;
                                                    container_lfb_hi_r    <= 4'd1;
                                                    container_lfb_lo_r    <= 4'b0100; // [2]
                                                    container_phase_r     <= CP_ATTR_WB;
                                                end else if (name_is_base) begin
                                                    // Return tp_base (field1) or None.
                                                    container_src_len_r     <= container_src_buf_r;
                                                    container_count_r       <= 7'd0;
                                                    container_lfb_hi_r      <= 4'd1;
                                                    container_lfb_lo_r      <= 4'b0010; // [1]
                                                    container_dmem_addr_r <=
                                                        pycore_obj_field_val_addr(
                                                            container_src_buf_r, 32'd1);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                    container_phase_r        <= CP_VAL;
                                                end else begin
                                                    container_src_len_r   <= container_src_buf_r;
                                                    container_count_r     <= 7'd0;
                                                    container_lfb_hi_r    <= 4'd1; // TYPE
                                                    container_lfb_lo_r    <= 4'd1; // type-walk
                                                    container_phase_r     <= CP_ATTR_TYPE;
                                                end
                                            end else begin
                                                container_type_trap_r <= 1'b1;
                                            end
                                        end
                                    end
                                end

                                // field0 val then tag (__dict__ or tp_dict).
                                // lfb_lo[1]: return the dict handle (dunder __dict__).
                                CP_ATTR_IDICT: begin
                                    if (!container_dmem_pending_r) begin
                                        if (!container_finishing_r) begin
                                            container_base_r <= container_rd_data_r[31:0];
                                            if (container_lfb_lo_r[1]) begin
                                                container_val_r <= container_rd_data_r;
                                            end
                                            container_dmem_addr_r <=
                                                pycore_obj_field_tag_addr(
                                                    (container_lfb_lo_r[0] ?
                                                     container_src_len_r :
                                                     container_src_buf_r),
                                                    32'd0);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_finishing_r    <= 1'b1;
                                        end else begin
                                            container_finishing_r <= 1'b0;
                                            if (container_rd_data_r[3:0] !=
                                                    PY_TAG_MUT_COLLEC) begin
                                                container_type_trap_r <= 1'b1;
                                            end else if (container_lfb_lo_r[1]) begin
                                                container_tag_r       <= PY_TAG_MUT_COLLEC;
                                                container_push_null_r <= 1'b0;
                                                container_lfb_lo_r    <= 4'b0100; // [2]
                                                container_phase_r     <= CP_ATTR_WB;
                                            end else begin
                                                container_dmem_addr_r    <= container_base_r;
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r        <= CP_HDR;
                                            end
                                        end
                                    end
                                end

                                CP_ATTR_TYPE: begin
                                    if ((container_src_len_r == 32'd0) ||
                                        (container_count_r >= 7'd8)) begin
                                        container_attr_error_r <= 1'b1;
                                    end else begin
                                        container_lfb_hi_r      <= 4'd1;
                                        container_lfb_lo_r      <= 4'd1;
                                        container_dmem_addr_r    <= container_src_len_r;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_ATTR_TDICT;
                                    end
                                end

                                CP_ATTR_TDICT: begin
                                    if (!container_dmem_pending_r) begin
                                        if (pycore_ob_kind(container_rd_data_r) !=
                                                PY_OBK_TYPE) begin
                                            container_type_trap_r <= 1'b1;
                                        end else begin
                                            container_finishing_r <= 1'b0;
                                            container_dmem_addr_r <=
                                                pycore_obj_field_val_addr(
                                                    container_src_len_r, 32'd0);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_ATTR_IDICT;
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
                                            // Empty table: miss → MRO / next base.
                                            if (!container_lfb_lo_r[0]) begin
                                                container_lfb_lo_r <= 4'd1;
                                                container_lfb_hi_r <= 4'd1;
                                                container_count_r  <= 7'd0;
                                                container_phase_r  <= CP_ATTR_TYPE;
                                            end else begin
                                                container_dmem_addr_r <=
                                                    pycore_obj_field_val_addr(
                                                        container_src_len_r, 32'd1);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r        <= CP_VAL;
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
                                            // Full probe without match → miss.
                                            if (!container_lfb_lo_r[0]) begin
                                                container_lfb_lo_r <= 4'd1;
                                                container_lfb_hi_r <= 4'd1;
                                                container_count_r  <= 7'd0;
                                                container_phase_r  <= CP_ATTR_TYPE;
                                            end else begin
                                                container_dmem_addr_r <=
                                                    pycore_obj_field_val_addr(
                                                        container_src_len_r, 32'd1);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r        <= CP_VAL;
                                            end
                                        end else begin
                                            container_probe_n_r <= container_probe_n_r + 32'd1;
                                            if (pycore_dict_slot_empty(
                                                    container_rd_data_r)) begin
                                                if (!container_lfb_lo_r[0]) begin
                                                    container_lfb_lo_r <= 4'd1;
                                                    container_lfb_hi_r <= 4'd1;
                                                    container_count_r  <= 7'd0;
                                                    container_phase_r  <= CP_ATTR_TYPE;
                                                end else begin
                                                    container_dmem_addr_r <=
                                                        pycore_obj_field_val_addr(
                                                            container_src_len_r, 32'd1);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                    container_phase_r        <= CP_VAL;
                                                end
                                            end else if (pycore_dict_tombstone(
                                                            container_rd_data_r[3:0])) begin
                                                if (container_probe_n_r + 32'd1
                                                        >= container_slot_count_r) begin
                                                    if (!container_lfb_lo_r[0]) begin
                                                        container_lfb_lo_r <= 4'd1;
                                                        container_lfb_hi_r <= 4'd1;
                                                        container_count_r  <= 7'd0;
                                                        container_phase_r  <= CP_ATTR_TYPE;
                                                    end else begin
                                                        container_dmem_addr_r <=
                                                            pycore_obj_field_val_addr(
                                                                container_src_len_r, 32'd1);
                                                        container_dmem_we_r      <= 1'b0;
                                                        container_dmem_pending_r <= 1'b1;
                                                        container_phase_r        <= CP_VAL;
                                                    end
                                                end else begin
                                                    container_probe_r <= cont_probe_next;
                                                    container_dmem_addr_r <=
                                                        pycore_dict_ktag_addr(
                                                            container_buf_r, cont_probe_next);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                end
                                            end else begin
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
                                            if (!container_lfb_lo_r[0]) begin
                                                container_lfb_lo_r <= 4'd1;
                                                container_lfb_hi_r <= 4'd1;
                                                container_count_r  <= 7'd0;
                                                container_phase_r  <= CP_ATTR_TYPE;
                                            end else begin
                                                container_dmem_addr_r <=
                                                    pycore_obj_field_val_addr(
                                                        container_src_len_r, 32'd1);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r        <= CP_VAL;
                                            end
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
                                        container_tag_r   <= container_rd_data_r[3:0];
                                        container_phase_r <= CP_ATTR_WB;
                                    end
                                end

                                // tp_base val (after type-dict miss).
                                CP_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_val_r  <= container_rd_data_r;
                                        container_base_r <= container_rd_data_r[31:0];
                                        container_dmem_addr_r <=
                                            pycore_obj_field_tag_addr(
                                                container_src_len_r, 32'd1);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_TAG;
                                    end
                                end

                                CP_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_lfb_lo_r[1]) begin
                                            // Dunder __base__: push tp_base or None.
                                            if (pycore_is_none(
                                                    container_rd_data_r[3:0],
                                                    container_val_r) ||
                                                (container_base_r == 32'd0)) begin
                                                container_tag_r       <= PY_TAG_CONTROL;
                                                container_val_r       <=
                                                    {124'b0, PY_CTL_NONE};
                                                container_push_null_r <= 1'b0;
                                                container_lfb_lo_r    <= 4'b0100; // [2]
                                                container_phase_r     <= CP_ATTR_WB;
                                            end else if (container_rd_data_r[3:0] !=
                                                         PY_TAG_OBJECT) begin
                                                container_type_trap_r <= 1'b1;
                                            end else begin
                                                container_tag_r       <= PY_TAG_OBJECT;
                                                container_push_null_r <= 1'b0;
                                                container_lfb_lo_r    <= 4'b0100; // [2]
                                                container_phase_r     <= CP_ATTR_WB;
                                            end
                                        end else if (pycore_is_none(
                                                container_rd_data_r[3:0],
                                                container_val_r) ||
                                            (container_base_r == 32'd0)) begin
                                            container_attr_error_r <= 1'b1;
                                        end else if (container_rd_data_r[3:0] !=
                                                     PY_TAG_OBJECT) begin
                                            container_type_trap_r <= 1'b1;
                                        end else begin
                                            container_src_len_r <= container_base_r;
                                            container_count_r   <= container_count_r + 7'd1;
                                            container_phase_r   <= CP_ATTR_TYPE;
                                        end
                                    end
                                end

                                CP_ATTR_WB: begin
                                    // OBJECT hit: may be OBK_BUILTIN id=0 staticmethod.
                                    // lfb_lo[2] set after unwrap so we don't loop.
                                    if ((container_tag_r == PY_TAG_OBJECT) &&
                                        !container_lfb_lo_r[2]) begin
                                        container_base_r       <= container_val_r[31:0];
                                        container_dmem_addr_r  <= container_val_r[31:0];
                                        container_dmem_we_r    <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r      <= CP_ATTR_STATIC0;
                                    end else if (container_push_null_r) begin
                                        // method_flag=1: [func,self] or [attr,NULL]
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(1));
                                        container_wb_data_r <= pycore_make_entry(
                                            container_tag_r, container_val_r);
                                        container_phase_r <= CP_ATTR_WB_SELF;
                                    end else if ((container_lfb_hi_r[0]) &&
                                                 (container_tag_r == PY_TAG_CODE_OBJECT) &&
                                                 !container_lfb_lo_r[2]) begin
                                        // method_flag=0 + TYPE source + CODE → bind
                                        // (staticmethod already unwrapped: push CODE)
                                        if ((heap_ptr_r + PYCORE_OBJ_BOUND_METHOD_BYTES)
                                                > PYCORE_HEAP_LIMIT) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_base_r       <= heap_ptr_r;
                                            heap_ptr_r             <= heap_ptr_r +
                                                PYCORE_OBJ_BOUND_METHOD_BYTES;
                                            container_dmem_addr_r  <= heap_ptr_r;
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <= pycore_pack_ob_head(
                                                PY_OBK_BOUND_METHOD, 32'd0, 64'd0);
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r      <= CP_ATTR_BOUND0;
                                        end
                                    end else begin
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(1));
                                        container_wb_data_r <= pycore_make_entry(
                                            container_tag_r, container_val_r);
                                        fetch_skip_r      <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end
                                end

                                // staticmethod unwrap: OBK_BUILTIN id=0, field1=CODE.
                                CP_ATTR_STATIC0: begin
                                    if (!container_dmem_pending_r) begin
                                        if (pycore_ob_kind(container_rd_data_r) !=
                                                PY_OBK_BUILTIN) begin
                                            // Plain object attribute — push as-is.
                                            container_tag_r   <= PY_TAG_OBJECT;
                                            container_val_r   <=
                                                {{96{1'b0}}, container_base_r};
                                            container_lfb_lo_r[2] <= 1'b1;
                                            container_phase_r <= CP_ATTR_WB;
                                        end else begin
                                            container_dmem_addr_r <=
                                                pycore_obj_field_val_addr(
                                                    container_base_r, 32'd0);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_ATTR_STATIC1;
                                        end
                                    end
                                end

                                CP_ATTR_STATIC1: begin
                                    if (!container_dmem_pending_r) begin
                                        // field0 val = builtin_id (stash in probe_r)
                                        container_probe_r <= container_rd_data_r[31:0];
                                        container_dmem_addr_r <=
                                            pycore_obj_field_tag_addr(
                                                container_base_r, 32'd0);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_ATTR_STATIC2;
                                    end
                                end

                                CP_ATTR_STATIC2: begin
                                    if (!container_dmem_pending_r) begin
                                        if ((container_rd_data_r[3:0] != PY_TAG_INT) ||
                                            (container_probe_r != 32'd0)) begin
                                            // Non-zero / non-INT builtin id: push as-is.
                                            container_tag_r   <= PY_TAG_OBJECT;
                                            container_val_r   <=
                                                {{96{1'b0}}, container_base_r};
                                            container_lfb_lo_r[2] <= 1'b1;
                                            container_phase_r <= CP_ATTR_WB;
                                        end else begin
                                            container_dmem_addr_r <=
                                                pycore_obj_field_val_addr(
                                                    container_base_r, 32'd1);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_ATTR_STATIC3;
                                        end
                                    end
                                end

                                CP_ATTR_STATIC3: begin
                                    if (!container_dmem_pending_r) begin
                                        container_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <=
                                            pycore_obj_field_tag_addr(
                                                container_base_r, 32'd1);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_ATTR_STATIC4;
                                    end
                                end

                                CP_ATTR_STATIC4: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_rd_data_r[3:0] !=
                                                PY_TAG_CODE_OBJECT) begin
                                            container_type_trap_r <= 1'b1;
                                        end else begin
                                            container_tag_r       <= PY_TAG_CODE_OBJECT;
                                            // val already holds field1 (CODE handle)
                                            container_lfb_lo_r[2] <= 1'b1; // static
                                            container_phase_r     <= CP_ATTR_WB;
                                        end
                                    end
                                end

                                CP_ATTR_WB_SELF: begin
                                    container_wb_we_r   <= 1'b1;
                                    container_wb_addr_r <= RF_AW'({2'b0, tos_r});
                                    if ((container_lfb_hi_r[0]) &&
                                        (container_tag_r == PY_TAG_CODE_OBJECT) &&
                                        !container_lfb_lo_r[2]) begin
                                        // Push receiver as self (rs1 still holds it).
                                        container_wb_data_r <= rs1_r;
                                    end else begin
                                        // Non-method attr, or staticmethod → NULL.
                                        container_wb_data_r <=
                                            pycore_make_control(PY_CTL_NULL);
                                    end
                                    tos_r             <= tos_r + RF_AW'(1);
                                    fetch_skip_r      <= 1'b1;
                                    container_phase_r <= CP_DONE;
                                end

                                CP_ATTR_BOUND0: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= container_base_r + 32'd16;
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, PY_TAG_OBJECT};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r      <= CP_ATTR_BOUND1;
                                    end
                                end

                                CP_ATTR_BOUND1: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <=
                                            pycore_obj_field_val_addr(container_base_r, 32'd0);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= container_val_r;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r      <= CP_ATTR_BOUND2;
                                    end
                                end

                                CP_ATTR_BOUND2: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <=
                                            pycore_obj_field_tag_addr(container_base_r, 32'd0);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r      <= CP_ATTR_BOUND3;
                                    end
                                end

                                CP_ATTR_BOUND3: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <=
                                            pycore_obj_field_val_addr(container_base_r, 32'd1);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= cont_rs1_val;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r      <= CP_DICT_WR_VVAL;
                                    end
                                end

                                // field1 tag then WB bound-method handle.
                                CP_DICT_WR_VVAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <=
                                            pycore_obj_field_tag_addr(container_base_r, 32'd1);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, cont_rs1_tag};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r      <= CP_DICT_WR_VTAG;
                                    end
                                end

                                CP_DICT_WR_VTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(1));
                                        container_wb_data_r <= pycore_make_entry(
                                            PY_TAG_OBJECT,
                                            {{96{1'b0}}, container_base_r});
                                        fetch_skip_r      <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_LOAD_ATTR

                        // =====================================================
                        // STORE_ATTR — upsert into instance __dict__; pop 2.
                        // =====================================================
                        CONT_STORE_ATTR: begin
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
                                        end else if (cont_rs1_tag != PY_TAG_OBJECT) begin
                                            container_type_trap_r <= 1'b1;
                                        end else if (pycore_attr_name_is_dunder_special(
                                                container_rd_data_r[3:0],
                                                container_val_r)) begin
                                            // No header mutation via STORE_ATTR.
                                            container_type_trap_r <= 1'b1;
                                        end else begin
                                            container_src_buf_r      <= cont_rs1_addr;
                                            container_finishing_r    <= 1'b0;
                                            container_dmem_addr_r    <= cont_rs1_addr;
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_ATTR_HEAD;
                                        end
                                    end
                                end

                                CP_ATTR_HEAD: begin
                                    if (!container_dmem_pending_r) begin
                                        if (pycore_ob_kind(container_rd_data_r) !=
                                                PY_OBK_INSTANCE) begin
                                            container_type_trap_r <= 1'b1;
                                        end else begin
                                            container_finishing_r <= 1'b0;
                                            container_dmem_addr_r <=
                                                pycore_obj_field_val_addr(
                                                    container_src_buf_r, 32'd0);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_ATTR_IDICT;
                                        end
                                    end
                                end

                                CP_ATTR_IDICT: begin
                                    if (!container_dmem_pending_r) begin
                                        if (!container_finishing_r) begin
                                            container_base_r <= container_rd_data_r[31:0];
                                            container_dmem_addr_r <=
                                                pycore_obj_field_tag_addr(
                                                    container_src_buf_r, 32'd0);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_finishing_r    <= 1'b1;
                                        end else begin
                                            container_finishing_r <= 1'b0;
                                            if (container_rd_data_r[3:0] !=
                                                    PY_TAG_MUT_COLLEC) begin
                                                container_type_trap_r <= 1'b1;
                                            end else begin
                                                // Value @ RF[tos-2]; key in tag/val.
                                                container_rf_addr_r     <=
                                                    RF_AW'(tos_r - RF_AW'(2));
                                                container_val_rf_addr_r <=
                                                    RF_AW'(tos_r - RF_AW'(2));
                                                container_insert_new_r  <= 1'b0;
                                                container_finishing_r   <= 1'b0;
                                                container_tomb_valid_r  <= 1'b0;
                                                container_tomb_idx_r    <= 32'd0;
                                                container_dmem_addr_r    <= container_base_r;
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r        <= CP_HDR;
                                            end
                                        end
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_finishing_r) begin
                                            container_dmem_addr_r <=
                                                pycore_dict_meta_addr(container_base_r);
                                            container_dmem_we_r <= 1'b1;
                                            container_dmem_wdata_r <= pycore_dict_meta(
                                                container_dict_version_r,
                                                container_order_len_r);
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_META_FINAL;
                                        end else begin
                                            container_slot_count_r <= cont_dict_hdr_slots[31:0];
                                            container_used_r       <= cont_dict_hdr_used;
                                            container_dmem_addr_r <=
                                                pycore_dict_meta_addr(container_base_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_DICT_META;
                                        end
                                    end
                                end

                                CP_DICT_META: begin
                                    if (!container_dmem_pending_r) begin
                                        container_order_len_r <=
                                            pycore_dict_order_len_from_meta(
                                                container_rd_data_r);
                                        container_dict_version_r <=
                                            pycore_dict_version_from_meta(
                                                container_rd_data_r);
                                        container_dmem_addr_r <=
                                            pycore_dict_table_ptr_addr(container_base_r);
                                        container_dmem_we_r <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_LIST_BUF;
                                    end
                                end

                                CP_DICT_META_FINAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_finishing_r <= 1'b0;
                                        tos_r <= tos_r - RF_AW'(2);
                                        fetch_skip_r <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end
                                end

                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        container_buf_r <= cont_dict_table_ptr;
                                        container_order_ptr_r <= cont_dict_order_ptr;
                                        if ((container_slot_count_r == 32'd0) ||
                                            (cont_dict_table_ptr == 32'd0)) begin
                                            if (EXCORE_EN &&
                                                pycore_trap_recoverable(PY_TRAP_DICT_GROW)) begin
                                                trap_marshal_pending_r     <= 1'b1;
                                                trap_marshal_code_r        <= PY_TRAP_DICT_GROW;
                                                trap_marshal_entry_count_r <= 3'd3;
                                                trap_marshal_entries_r[0]  <=
                                                    pycore_make_mut(
                                                        PY_MUT_DICT,
                                                        {32'b0, container_base_r}, 1'b0);
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
                                                            pycore_make_mut(
                                                                PY_MUT_DICT,
                                                                {32'b0,
                                                                 container_base_r}, 1'b0);
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
                                                        pycore_make_mut(
                                                            PY_MUT_DICT,
                                                            {32'b0,
                                                             container_base_r}, 1'b0);
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
                                            if (pycore_dict_slot_empty(
                                                    container_rd_data_r)) begin
                                                if (cont_dict_needs_grow) begin
                                                    if (EXCORE_EN &&
                                                        pycore_trap_recoverable(
                                                            PY_TRAP_DICT_GROW)) begin
                                                        trap_marshal_pending_r     <= 1'b1;
                                                        trap_marshal_code_r        <=
                                                            PY_TRAP_DICT_GROW;
                                                        trap_marshal_entry_count_r <= 3'd3;
                                                    trap_marshal_entries_r[0]  <=
                                                        pycore_make_mut(
                                                            PY_MUT_DICT,
                                                            {32'b0,
                                                             container_base_r}, 1'b0);
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
                                        container_dmem_wdata_r <=
                                            pycore_dict_key_tag_word(
                                                container_tag_r, container_val_r);
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
                                            container_dmem_addr_r <=
                                                pycore_dict_order_val_addr(
                                                    container_order_ptr_r,
                                                    container_order_len_r[31:0]);
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <= container_val_r;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_ORDER_VAL;
                                        end else begin
                                            tos_r             <= tos_r - RF_AW'(2);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end
                                    end
                                end

                                CP_DICT_ORDER_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r <=
                                            pycore_dict_order_tag_addr(
                                                container_order_ptr_r,
                                                container_order_len_r[31:0]);
                                        container_dmem_we_r <= 1'b1;
                                        container_dmem_wdata_r <=
                                            {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_ORDER_TAG;
                                    end
                                end

                                CP_DICT_ORDER_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_used_r <= container_used_r + 64'd1;
                                        container_order_len_r <=
                                            container_order_len_r + 64'd1;
                                        container_dict_version_r <=
                                            container_dict_version_r + 64'd1;
                                        container_insert_new_r <= 1'b0;
                                        container_dmem_addr_r <= container_base_r;
                                        container_dmem_we_r <= 1'b1;
                                        container_dmem_wdata_r <= pycore_dict_header(
                                            {32'b0, container_slot_count_r},
                                            container_used_r + 64'd1);
                                        container_dmem_pending_r <= 1'b1;
                                        container_finishing_r <= 1'b1;
                                        container_phase_r <= CP_HDR;
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_STORE_ATTR

                        // =====================================================
                        // DELETE_ATTR — tombstone in instance __dict__; pop 1.
                        // Miss → ATTR_ERROR (not mem_fault).
                        // =====================================================
                        CONT_DELETE_ATTR: begin
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
                                        end else if (cont_rs1_tag != PY_TAG_OBJECT) begin
                                            container_type_trap_r <= 1'b1;
                                        end else if (pycore_attr_name_is_dunder_special(
                                                container_rd_data_r[3:0],
                                                container_val_r)) begin
                                            // No header mutation via DELETE_ATTR.
                                            container_type_trap_r <= 1'b1;
                                        end else begin
                                            container_src_buf_r      <= cont_rs1_addr;
                                            container_finishing_r    <= 1'b0;
                                            container_dmem_addr_r    <= cont_rs1_addr;
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_ATTR_HEAD;
                                        end
                                    end
                                end

                                CP_ATTR_HEAD: begin
                                    if (!container_dmem_pending_r) begin
                                        if (pycore_ob_kind(container_rd_data_r) !=
                                                PY_OBK_INSTANCE) begin
                                            container_type_trap_r <= 1'b1;
                                        end else begin
                                            container_finishing_r <= 1'b0;
                                            container_dmem_addr_r <=
                                                pycore_obj_field_val_addr(
                                                    container_src_buf_r, 32'd0);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_ATTR_IDICT;
                                        end
                                    end
                                end

                                CP_ATTR_IDICT: begin
                                    if (!container_dmem_pending_r) begin
                                        if (!container_finishing_r) begin
                                            container_base_r <= container_rd_data_r[31:0];
                                            container_dmem_addr_r <=
                                                pycore_obj_field_tag_addr(
                                                    container_src_buf_r, 32'd0);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_finishing_r    <= 1'b1;
                                        end else begin
                                            container_finishing_r <= 1'b0;
                                            if (container_rd_data_r[3:0] !=
                                                    PY_TAG_MUT_COLLEC) begin
                                                container_type_trap_r <= 1'b1;
                                            end else begin
                                                container_dmem_addr_r    <= container_base_r;
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r        <= CP_HDR;
                                            end
                                        end
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_finishing_r) begin
                                            container_dmem_addr_r <=
                                                pycore_dict_meta_addr(container_base_r);
                                            container_dmem_we_r <= 1'b1;
                                            container_dmem_wdata_r <= pycore_dict_meta(
                                                container_dict_version_r,
                                                container_order_len_r);
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_META_FINAL;
                                        end else begin
                                            container_slot_count_r <= cont_dict_hdr_slots[31:0];
                                            container_used_r       <= cont_dict_hdr_used;
                                            container_dmem_addr_r <=
                                                pycore_dict_meta_addr(container_base_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_DICT_META;
                                        end
                                    end
                                end

                                CP_DICT_META: begin
                                    if (!container_dmem_pending_r) begin
                                        container_order_len_r <=
                                            pycore_dict_order_len_from_meta(
                                                container_rd_data_r);
                                        container_dict_version_r <=
                                            pycore_dict_version_from_meta(
                                                container_rd_data_r);
                                        container_dmem_addr_r <=
                                            pycore_dict_table_ptr_addr(container_base_r);
                                        container_dmem_we_r <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_LIST_BUF;
                                    end
                                end

                                CP_DICT_META_FINAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_finishing_r <= 1'b0;
                                        tos_r <= tos_r - RF_AW'(1);
                                        fetch_skip_r <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end
                                end

                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        container_buf_r <= cont_dict_table_ptr;
                                        container_order_ptr_r <= cont_dict_order_ptr;
                                        if ((container_slot_count_r == 32'd0) ||
                                            (cont_dict_table_ptr == 32'd0)) begin
                                            container_attr_error_r <= 1'b1;
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
                                            container_attr_error_r <= 1'b1;
                                        end else begin
                                            container_probe_n_r <= container_probe_n_r + 32'd1;
                                            if (pycore_dict_slot_empty(
                                                    container_rd_data_r)) begin
                                                container_attr_error_r <= 1'b1;
                                            end else if (pycore_dict_tombstone(
                                                            container_rd_data_r[3:0])) begin
                                                if (container_probe_n_r + 32'd1
                                                        >= container_slot_count_r) begin
                                                    container_attr_error_r <= 1'b1;
                                                end else begin
                                                    container_probe_r <= cont_probe_next;
                                                    container_dmem_addr_r <=
                                                        pycore_dict_ktag_addr(
                                                            container_buf_r, cont_probe_next);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                end
                                            end else begin
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
                                            container_dmem_addr_r  <= pycore_dict_ktag_addr(
                                                container_buf_r, container_probe_r);
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <=
                                                {124'b0, PY_TAG_TOMBSTONE};
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_WR_KTAG;
                                        end else if (container_probe_n_r
                                                     >= container_slot_count_r) begin
                                            container_attr_error_r <= 1'b1;
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

                                CP_DICT_WR_KTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_order_idx_r <= 32'd0;
                                        container_dmem_addr_r <=
                                            pycore_dict_order_val_addr(
                                                container_order_ptr_r, 32'd0);
                                        container_dmem_we_r <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_ORDER_SCAN_VAL;
                                    end
                                end

                                CP_DICT_ORDER_SCAN_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_order_shift_val_r <=
                                            container_rd_data_r;
                                        container_dmem_addr_r <=
                                            pycore_dict_order_tag_addr(
                                                container_order_ptr_r,
                                                container_order_idx_r);
                                        container_dmem_we_r <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_ORDER_SCAN_TAG;
                                    end
                                end

                                CP_DICT_ORDER_SCAN_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        if (pycore_dict_key_rich_eq(
                                                container_tag_r,
                                                container_val_r,
                                                container_rd_data_r[3:0],
                                                container_order_shift_val_r)) begin
                                            if (container_order_idx_r + 32'd1 >=
                                                container_order_len_r[31:0]) begin
                                                container_used_r <=
                                                    container_used_r - 64'd1;
                                                container_order_len_r <=
                                                    container_order_len_r - 64'd1;
                                                container_dict_version_r <=
                                                    container_dict_version_r + 64'd1;
                                                container_dmem_addr_r <=
                                                    container_base_r;
                                                container_dmem_we_r <= 1'b1;
                                                container_dmem_wdata_r <=
                                                    pycore_dict_header(
                                                        {32'b0,
                                                         container_slot_count_r},
                                                        container_used_r - 64'd1);
                                                container_dmem_pending_r <= 1'b1;
                                                container_finishing_r <= 1'b1;
                                                container_phase_r <= CP_HDR;
                                            end else begin
                                                container_dmem_addr_r <=
                                                    pycore_dict_order_val_addr(
                                                        container_order_ptr_r,
                                                        container_order_idx_r +
                                                        32'd1);
                                                container_dmem_we_r <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r <=
                                                    CP_DICT_ORDER_SHIFT_VAL_RD;
                                            end
                                        end else if (container_order_idx_r + 32'd1 >=
                                                     container_order_len_r[31:0]) begin
                                            container_attr_error_r <= 1'b1;
                                        end else begin
                                            container_order_idx_r <=
                                                container_order_idx_r + 32'd1;
                                            container_dmem_addr_r <=
                                                pycore_dict_order_val_addr(
                                                    container_order_ptr_r,
                                                    container_order_idx_r + 32'd1);
                                            container_dmem_we_r <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <=
                                                CP_DICT_ORDER_SCAN_VAL;
                                        end
                                    end
                                end

                                CP_DICT_ORDER_SHIFT_VAL_RD: begin
                                    if (!container_dmem_pending_r) begin
                                        container_order_shift_val_r <=
                                            container_rd_data_r;
                                        container_dmem_addr_r <=
                                            pycore_dict_order_val_addr(
                                                container_order_ptr_r,
                                                container_order_idx_r);
                                        container_dmem_we_r <= 1'b1;
                                        container_dmem_wdata_r <=
                                            container_rd_data_r;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <=
                                            CP_DICT_ORDER_SHIFT_VAL_WR;
                                    end
                                end

                                CP_DICT_ORDER_SHIFT_VAL_WR: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r <=
                                            pycore_dict_order_tag_addr(
                                                container_order_ptr_r,
                                                container_order_idx_r + 32'd1);
                                        container_dmem_we_r <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <=
                                            CP_DICT_ORDER_SHIFT_TAG_RD;
                                    end
                                end

                                CP_DICT_ORDER_SHIFT_TAG_RD: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r <=
                                            pycore_dict_order_tag_addr(
                                                container_order_ptr_r,
                                                container_order_idx_r);
                                        container_dmem_we_r <= 1'b1;
                                        container_dmem_wdata_r <=
                                            {124'b0, container_rd_data_r[3:0]};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <=
                                            CP_DICT_ORDER_SHIFT_TAG_WR;
                                    end
                                end

                                CP_DICT_ORDER_SHIFT_TAG_WR: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_order_idx_r + 32'd2 <
                                            container_order_len_r[31:0]) begin
                                            container_order_idx_r <=
                                                container_order_idx_r + 32'd1;
                                            container_dmem_addr_r <=
                                                pycore_dict_order_val_addr(
                                                    container_order_ptr_r,
                                                    container_order_idx_r +
                                                    32'd2);
                                            container_dmem_we_r <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <=
                                                CP_DICT_ORDER_SHIFT_VAL_RD;
                                        end else begin
                                            container_used_r <=
                                                container_used_r - 64'd1;
                                            container_order_len_r <=
                                                container_order_len_r - 64'd1;
                                            container_dict_version_r <=
                                                container_dict_version_r + 64'd1;
                                            container_dmem_addr_r <=
                                                container_base_r;
                                            container_dmem_we_r <= 1'b1;
                                            container_dmem_wdata_r <=
                                                pycore_dict_header(
                                                    {32'b0,
                                                     container_slot_count_r},
                                                    container_used_r - 64'd1);
                                            container_dmem_pending_r <= 1'b1;
                                            container_finishing_r <= 1'b1;
                                            container_phase_r <= CP_HDR;
                                        end
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_DELETE_ATTR

