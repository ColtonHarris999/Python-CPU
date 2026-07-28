// pycore_cont_dict.svh — DICT/SET arms of S_CONTAINER.
// Included inside pycore_core's unique case (container_op_r). Do not compile alone.
                        CONT_BUILD_MAP: begin
                            unique case (container_phase_r)

                                // Phase 0: OOM check, allocate header + table.
                                CP_INIT: begin
                                    if ((heap_ptr_r + pycore_dict_alloc_bytes(cont_dict_min_slots))
                                            > PYCORE_HEAP_LIMIT) begin
                                        container_mem_fault_r <= 1'b1;
                                    end else begin
                                        container_slot_count_r <= cont_dict_min_slots;
                                        container_used_r       <= 64'd0;
                                        container_probe_n_r    <= 32'd0;
                                        container_insert_new_r <= 1'b0;
                                        container_finishing_r  <= 1'b0;
                                        container_base_r       <= heap_ptr_r;
                                        // Contiguous table immediately after 32B object.
                                        container_buf_r        <= heap_ptr_r + 32'd32;
                                        heap_ptr_r             <= heap_ptr_r +
                                            pycore_dict_alloc_bytes(cont_dict_min_slots);
                                        container_dmem_addr_r  <= heap_ptr_r;
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= pycore_dict_header(
                                            {32'b0, cont_dict_min_slots}, 64'd0);
                                        container_dmem_pending_r <= 1'b1;
                                        // Pre-set RF addr to first pair's key.
                                        container_rf_addr_r <= RF_AW'(
                                            {2'b0, tos_r} - {2'b0, container_count_r, 1'b0});
                                        container_phase_r <= CP_HDR;
                                    end
                                end

                                // Phase 1: header write ack → write table_ptr,
                                // or finish used-count rewrite / empty commit.
                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_finishing_r) begin
                                            // Final used-count header rewrite acked → commit.
                                            container_finishing_r <= 1'b0;
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(
                                                {2'b0, tos_r}
                                                - {2'b0, container_count_r, 1'b0});
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_DICT,
                                                {{96{1'b0}}, container_base_r});
                                            tos_r <= tos_r
                                                - {2'b0, container_count_r, 1'b0}
                                                + 7'd1;
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            // Install table_ptr at obj+16 (0 only
                                            // if slot_count were 0; BUILD_MAP always
                                            // allocates ≥4 slots via min_slots).
                                            container_dmem_addr_r <=
                                                pycore_dict_table_ptr_addr(container_base_r);
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <=
                                                {{64{1'b0}}, {32'b0, container_buf_r}};
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_LIST_BUF;
                                        end
                                    end
                                end

                                // Phase 2: table_ptr write ack → probe or empty done.
                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_count_r == 7'd0) begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'({2'b0, tos_r});
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_DICT, {{96{1'b0}}, container_base_r});
                                            tos_r             <= tos_r + RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            container_tag_r <= cont_rf_rs1_tag;
                                            container_val_r <= cont_rf_rs1_val;
                                            if (!pycore_dict_key_tag_ok(cont_rf_rs1_tag)) begin
                                                container_type_trap_r <= 1'b1;
                                            end else begin
                                                container_val_rf_addr_r <= RF_AW'(
                                                    {2'b0, tos_r}
                                                    - {2'b0, container_count_r, 1'b0}
                                                    + 9'd1);
                                                begin
                                                    logic [31:0] probe0;
                                                    probe0 = pycore_dict_key_hash(
                                                        cont_rf_rs1_tag, cont_rf_rs1_val)
                                                        & (container_slot_count_r - 32'd1);
                                                    container_probe_r   <= probe0;
                                                    container_probe_n_r <= 32'd0;
                                                    container_dmem_addr_r <=
                                                        pycore_dict_ktag_addr(
                                                            container_buf_r, probe0);
                                                end
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r <= CP_DICT_PROBE;
                                            end
                                        end
                                    end
                                end

                                // Probe: occupied → rich_eq at CHK_VAL.
                                CP_DICT_PROBE: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_probe_n_r >= container_slot_count_r) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_probe_n_r <= container_probe_n_r + 32'd1;
                                            if (container_rd_data_r[3:0] == PY_TAG_UNINIT) begin
                                                container_insert_new_r <= 1'b1;
                                                container_dmem_addr_r  <= pycore_dict_kval_addr(
                                                    container_buf_r, container_probe_r);
                                                container_dmem_we_r    <= 1'b1;
                                                container_dmem_wdata_r <= container_val_r;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r <= CP_DICT_WR_KVAL;
                                            end else if (pycore_dict_tombstone(
                                                            container_rd_data_r[3:0])) begin
                                                // BUILD_MAP: treat tombstone like occupied
                                                // mismatch — continue (should not appear).
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
                                                container_probe_tag_r    <=
                                                    container_rd_data_r[3:0];
                                                container_dmem_addr_r    <=
                                                    pycore_dict_kval_addr(
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
                                        if (container_insert_new_r) begin
                                            container_used_r <= container_used_r + 64'd1;
                                            container_insert_new_r <= 1'b0;
                                        end
                                        container_rf_addr_r <= container_val_rf_addr_r;
                                        container_phase_r   <= CP_DICT_RD_VAL;
                                    end
                                end

                                CP_DICT_RD_VAL: begin
                                    container_tag_r <= cont_rf_rs1_tag;
                                    container_dmem_addr_r  <= pycore_dict_vval_addr(
                                        container_buf_r, container_probe_r);
                                    container_dmem_we_r    <= 1'b1;
                                    container_dmem_wdata_r <= cont_rf_rs1_val;
                                    container_dmem_pending_r <= 1'b1;
                                    container_phase_r <= CP_DICT_WR_VVAL;
                                end

                                CP_DICT_WR_VVAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_dict_vtag_addr(
                                            container_buf_r, container_probe_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_WR_VTAG;
                                    end
                                end

                                CP_DICT_WR_VTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_idx_r + 7'd1 < container_count_r) begin
                                            container_idx_r <= container_idx_r + 7'd1;
                                            container_rf_addr_r <= RF_AW'(
                                                {2'b0, tos_r}
                                                - {2'b0, container_count_r, 1'b0}
                                                + {2'b0, container_idx_r, 1'b0}
                                                + 9'd2);
                                            container_val_rf_addr_r <= RF_AW'(
                                                {2'b0, tos_r}
                                                - {2'b0, container_count_r, 1'b0}
                                                + {2'b0, container_idx_r, 1'b0}
                                                + 9'd3);
                                            container_phase_r <= CP_DICT_HASH;
                                        end else begin
                                            container_dmem_addr_r  <= container_base_r;
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <= pycore_dict_header(
                                                {32'b0, container_slot_count_r},
                                                container_used_r);
                                            container_dmem_pending_r <= 1'b1;
                                            container_finishing_r  <= 1'b1;
                                            container_phase_r <= CP_HDR;
                                        end
                                    end
                                end

                                CP_DICT_HASH: begin
                                    container_tag_r <= cont_rf_rs1_tag;
                                    container_val_r <= cont_rf_rs1_val;
                                    if (!pycore_dict_key_tag_ok(cont_rf_rs1_tag)) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        container_probe_r   <= cont_dict_hash;
                                        container_probe_n_r <= 32'd0;
                                        container_dmem_addr_r <= pycore_dict_ktag_addr(
                                            container_buf_r, cont_dict_hash);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_PROBE;
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_BUILD_MAP

                        CONT_SUBSCR_DICT: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (!pycore_dict_key_tag_ok(cont_rs2_tag)) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        container_tag_r <= cont_rs2_tag;
                                        container_val_r <= cont_rs2_val;
                                        container_base_r         <= cont_rs1_addr;
                                        container_dmem_addr_r    <= cont_rs1_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
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
                                            // Empty dict → KeyError analog.
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
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                        container_wb_data_r <= pycore_make_entry(
                                            container_rd_data_r[3:0], container_val_r);
                                        tos_r             <= tos_r - RF_AW'(1);
                                        fetch_skip_r      <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_SUBSCR_DICT

                        CONT_STORE_DICT: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (!pycore_dict_key_tag_ok(cont_rs1_tag)) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        container_tag_r <= cont_rs1_tag;
                                        container_val_r <= cont_rs1_val;
                                        // Point RF port at value early so grow
                                        // marshal can assemble entry2.
                                        container_rf_addr_r     <= RF_AW'(tos_r - RF_AW'(3));
                                        container_val_rf_addr_r <= RF_AW'(tos_r - RF_AW'(3));
                                        container_insert_new_r  <= 1'b0;
                                        container_finishing_r   <= 1'b0;
                                        container_tomb_valid_r  <= 1'b0;
                                        container_tomb_idx_r    <= 32'd0;
                                        container_base_r         <= cont_rs2_addr;
                                        container_dmem_addr_r    <= cont_rs2_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_finishing_r) begin
                                            container_finishing_r <= 1'b0;
                                            tos_r             <= tos_r - RF_AW'(3);
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
                                            // Empty table → DICT_GROW before insert.
                                            if (EXCORE_EN &&
                                                pycore_trap_recoverable(PY_TRAP_DICT_GROW)) begin
                                                trap_marshal_pending_r     <= 1'b1;
                                                trap_marshal_code_r        <= PY_TRAP_DICT_GROW;
                                                trap_marshal_entry_count_r <= 3'd3;
                                                trap_marshal_entries_r[0]  <= rs2_r;
                                                trap_marshal_entries_r[1]  <= rs1_r;
                                                trap_marshal_entries_r[2]  <=
                                                    pycore_make_entry(cont_rf_rs1_tag,
                                                                      cont_rf_rs1_val);
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
                                            // Full probe without UNINIT: insert at
                                            // first tombstone if any, else fault.
                                            if (container_tomb_valid_r) begin
                                                if (cont_dict_needs_grow) begin
                                                    if (EXCORE_EN &&
                                                        pycore_trap_recoverable(
                                                            PY_TRAP_DICT_GROW)) begin
                                                        trap_marshal_pending_r     <= 1'b1;
                                                        trap_marshal_code_r        <=
                                                            PY_TRAP_DICT_GROW;
                                                        trap_marshal_entry_count_r <= 3'd3;
                                                        trap_marshal_entries_r[0]  <= rs2_r;
                                                        trap_marshal_entries_r[1]  <= rs1_r;
                                                        trap_marshal_entries_r[2]  <=
                                                            pycore_make_entry(
                                                                cont_rf_rs1_tag,
                                                                cont_rf_rs1_val);
                                                        container_phase_r          <= CP_DONE;
                                                    end else begin
                                                        container_dict_grow_trap_r <= 1'b1;
                                                    end
                                                end else begin
                                                    container_probe_r      <= container_tomb_idx_r;
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
                                                // No empty/tombstone: grow.
                                                if (EXCORE_EN &&
                                                    pycore_trap_recoverable(
                                                        PY_TRAP_DICT_GROW)) begin
                                                    trap_marshal_pending_r     <= 1'b1;
                                                    trap_marshal_code_r        <=
                                                        PY_TRAP_DICT_GROW;
                                                    trap_marshal_entry_count_r <= 3'd3;
                                                    trap_marshal_entries_r[0]  <= rs2_r;
                                                    trap_marshal_entries_r[1]  <= rs1_r;
                                                    trap_marshal_entries_r[2]  <=
                                                        pycore_make_entry(
                                                            cont_rf_rs1_tag,
                                                            cont_rf_rs1_val);
                                                    container_phase_r          <= CP_DONE;
                                                end else begin
                                                    container_dict_grow_trap_r <= 1'b1;
                                                end
                                            end
                                        end else begin
                                            container_probe_n_r <= container_probe_n_r + 32'd1;
                                            if (container_rd_data_r[3:0] == PY_TAG_UNINIT) begin
                                                // Insert at first tombstone or here.
                                                if (cont_dict_needs_grow) begin
                                                    if (EXCORE_EN &&
                                                        pycore_trap_recoverable(
                                                            PY_TRAP_DICT_GROW)) begin
                                                        trap_marshal_pending_r     <= 1'b1;
                                                        trap_marshal_code_r        <=
                                                            PY_TRAP_DICT_GROW;
                                                        trap_marshal_entry_count_r <= 3'd3;
                                                        trap_marshal_entries_r[0]  <= rs2_r;
                                                        trap_marshal_entries_r[1]  <= rs1_r;
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
                                                    container_tomb_idx_r   <= container_probe_r;
                                                end
                                                if (container_probe_n_r + 32'd1
                                                        >= container_slot_count_r) begin
                                                    // Fall through next cycle via
                                                    // probe_n >= slot_count path.
                                                    container_probe_r <= cont_probe_next;
                                                    container_dmem_addr_r <=
                                                        pycore_dict_ktag_addr(
                                                            container_buf_r, cont_probe_next);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
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
                                            // Overwrite existing key — used unchanged.
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
                                    container_tag_r <= cont_rf_rs1_tag;
                                    container_dmem_addr_r  <= pycore_dict_vval_addr(
                                        container_buf_r, container_probe_r);
                                    container_dmem_we_r    <= 1'b1;
                                    container_dmem_wdata_r <= cont_rf_rs1_val;
                                    container_dmem_pending_r <= 1'b1;
                                    container_phase_r <= CP_DICT_WR_VVAL;
                                end

                                CP_DICT_WR_VVAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_dict_vtag_addr(
                                            container_buf_r, container_probe_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, container_tag_r};
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
                                            tos_r             <= tos_r - RF_AW'(3);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_STORE_DICT

                        CONT_CONTAINS_DICT: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (!pycore_dict_key_tag_ok(cont_rs1_tag)) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        container_tag_r <= cont_rs1_tag;
                                        container_val_r <= cont_rs1_val;
                                        container_base_r         <= cont_rs2_addr;
                                        container_dmem_addr_r    <= cont_rs2_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
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
                                            // Empty → miss (False / True for not-in).
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                 cur_arg_r[0]});
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
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
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                 cur_arg_r[0]});
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            container_probe_n_r <= container_probe_n_r + 32'd1;
                                            if (container_rd_data_r[3:0] == PY_TAG_UNINIT) begin
                                                container_wb_we_r   <= 1'b1;
                                                container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                                container_wb_data_r <= pycore_make_entry(
                                                    PY_TAG_BOOL,
                                                    {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                     cur_arg_r[0]});
                                                tos_r             <= tos_r - RF_AW'(1);
                                                fetch_skip_r      <= 1'b1;
                                                container_phase_r <= CP_DONE;
                                            end else if (pycore_dict_tombstone(
                                                            container_rd_data_r[3:0])) begin
                                                if (container_probe_n_r + 32'd1
                                                        >= container_slot_count_r) begin
                                                    container_wb_we_r   <= 1'b1;
                                                    container_wb_addr_r <=
                                                        RF_AW'(tos_r - RF_AW'(2));
                                                    container_wb_data_r <= pycore_make_entry(
                                                        PY_TAG_BOOL,
                                                        {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                         cur_arg_r[0]});
                                                    tos_r             <= tos_r - RF_AW'(1);
                                                    fetch_skip_r      <= 1'b1;
                                                    container_phase_r <= CP_DONE;
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
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                 ~cur_arg_r[0]});
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else if (container_probe_n_r
                                                     >= container_slot_count_r) begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                 cur_arg_r[0]});
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
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

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_CONTAINS_DICT

                        CONT_DELETE_DICT: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (!pycore_dict_key_tag_ok(cont_rs1_tag)) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        container_tag_r <= cont_rs1_tag;
                                        container_val_r <= cont_rs1_val;
                                        container_finishing_r    <= 1'b0;
                                        container_base_r         <= cont_rs2_addr;
                                        container_dmem_addr_r    <= cont_rs2_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_finishing_r) begin
                                            container_finishing_r <= 1'b0;
                                            tos_r             <= tos_r - RF_AW'(2);
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
                                            // Tombstone the key tag; used-- via header.
                                            container_dmem_addr_r  <= pycore_dict_ktag_addr(
                                                container_buf_r, container_probe_r);
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <=
                                                {124'b0, PY_TAG_TOMBSTONE};
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_WR_KTAG;
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

                                CP_DICT_WR_KTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= container_base_r;
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= pycore_dict_header(
                                            {32'b0, container_slot_count_r},
                                            container_used_r - 64'd1);
                                        container_dmem_pending_r <= 1'b1;
                                        container_used_r       <= container_used_r - 64'd1;
                                        container_finishing_r  <= 1'b1;
                                        container_phase_r <= CP_HDR;
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_DELETE_DICT

                        CONT_BUILD_SET: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if ((heap_ptr_r + pycore_set_alloc_bytes(cont_set_min_slots))
                                            > PYCORE_HEAP_LIMIT) begin
                                        container_mem_fault_r <= 1'b1;
                                    end else begin
                                        container_slot_count_r <= cont_set_min_slots;
                                        container_used_r       <= 64'd0;
                                        container_probe_n_r    <= 32'd0;
                                        container_insert_new_r <= 1'b0;
                                        container_finishing_r  <= 1'b0;
                                        container_base_r       <= heap_ptr_r;
                                        container_buf_r        <= heap_ptr_r + 32'd32;
                                        heap_ptr_r             <= heap_ptr_r +
                                            pycore_set_alloc_bytes(cont_set_min_slots);
                                        container_dmem_addr_r  <= heap_ptr_r;
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= pycore_set_header(
                                            {32'b0, cont_set_min_slots}, 64'd0);
                                        container_dmem_pending_r <= 1'b1;
                                        // First element at tos-count.
                                        container_rf_addr_r <= RF_AW'(
                                            {2'b0, tos_r} - {2'b0, container_count_r});
                                        container_phase_r <= CP_HDR;
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_finishing_r) begin
                                            container_finishing_r <= 1'b0;
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(
                                                {2'b0, tos_r} - {2'b0, container_count_r});
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_SET,
                                                {{96{1'b0}}, container_base_r});
                                            tos_r <= tos_r - {2'b0, container_count_r}
                                                   + 7'd1;
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            container_dmem_addr_r <=
                                                pycore_set_table_ptr_addr(container_base_r);
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <=
                                                {{64{1'b0}}, {32'b0, container_buf_r}};
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_LIST_BUF;
                                        end
                                    end
                                end

                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_count_r == 7'd0) begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'({2'b0, tos_r});
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_SET, {{96{1'b0}}, container_base_r});
                                            tos_r             <= tos_r + RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            container_tag_r <= cont_rf_rs1_tag;
                                            container_val_r <= cont_rf_rs1_val;
                                            if (!pycore_dict_key_tag_ok(cont_rf_rs1_tag)) begin
                                                container_type_trap_r <= 1'b1;
                                            end else begin
                                                begin
                                                    logic [31:0] probe0;
                                                    probe0 = pycore_dict_key_hash(
                                                        cont_rf_rs1_tag, cont_rf_rs1_val)
                                                        & (container_slot_count_r - 32'd1);
                                                    container_probe_r   <= probe0;
                                                    container_probe_n_r <= 32'd0;
                                                    container_dmem_addr_r <=
                                                        pycore_set_tag_addr(
                                                            container_buf_r, probe0);
                                                end
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r <= CP_DICT_PROBE;
                                            end
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
                                                container_insert_new_r <= 1'b1;
                                                container_dmem_addr_r  <= pycore_set_val_addr(
                                                    container_buf_r, container_probe_r);
                                                container_dmem_we_r    <= 1'b1;
                                                container_dmem_wdata_r <= container_val_r;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r <= CP_DICT_WR_KVAL;
                                            end else if (pycore_dict_tombstone(
                                                            container_rd_data_r[3:0])) begin
                                                if (container_probe_n_r + 32'd1
                                                        >= container_slot_count_r) begin
                                                    container_mem_fault_r <= 1'b1;
                                                end else begin
                                                    container_probe_r <= cont_probe_next;
                                                    container_dmem_addr_r <=
                                                        pycore_set_tag_addr(
                                                            container_buf_r, cont_probe_next);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                end
                                            end else begin
                                                container_probe_tag_r    <=
                                                    container_rd_data_r[3:0];
                                                container_dmem_addr_r    <=
                                                    pycore_set_val_addr(
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
                                            // Duplicate element — skip insert; advance.
                                            container_insert_new_r <= 1'b0;
                                            if (container_idx_r + 7'd1 < container_count_r) begin
                                                container_idx_r <= container_idx_r + 7'd1;
                                                container_rf_addr_r <= RF_AW'(
                                                    {2'b0, tos_r}
                                                    - {2'b0, container_count_r}
                                                    + {2'b0, container_idx_r} + 9'd1);
                                                container_phase_r <= CP_DICT_HASH;
                                            end else begin
                                                container_dmem_addr_r  <= container_base_r;
                                                container_dmem_we_r    <= 1'b1;
                                                container_dmem_wdata_r <= pycore_set_header(
                                                    {32'b0, container_slot_count_r},
                                                    container_used_r);
                                                container_dmem_pending_r <= 1'b1;
                                                container_finishing_r  <= 1'b1;
                                                container_phase_r <= CP_HDR;
                                            end
                                        end else if (container_probe_n_r
                                                     >= container_slot_count_r) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_probe_r <= cont_probe_next;
                                            container_dmem_addr_r <= pycore_set_tag_addr(
                                                container_buf_r, cont_probe_next);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_PROBE;
                                        end
                                    end
                                end

                                CP_DICT_WR_KVAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_set_tag_addr(
                                            container_buf_r, container_probe_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_WR_KTAG;
                                    end
                                end

                                CP_DICT_WR_KTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_insert_new_r) begin
                                            container_used_r <= container_used_r + 64'd1;
                                            container_insert_new_r <= 1'b0;
                                        end
                                        if (container_idx_r + 7'd1 < container_count_r) begin
                                            container_idx_r <= container_idx_r + 7'd1;
                                            // NBA: idx still old → next elem at +1.
                                            container_rf_addr_r <= RF_AW'(
                                                {2'b0, tos_r}
                                                - {2'b0, container_count_r}
                                                + {2'b0, container_idx_r} + 9'd1);
                                            container_phase_r <= CP_DICT_HASH;
                                        end else begin
                                            // NBA: insert_new still old → include +1 if set.
                                            container_dmem_addr_r  <= container_base_r;
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <= pycore_set_header(
                                                {32'b0, container_slot_count_r},
                                                container_used_r +
                                                    (container_insert_new_r ? 64'd1 : 64'd0));
                                            container_dmem_pending_r <= 1'b1;
                                            container_finishing_r  <= 1'b1;
                                            container_phase_r <= CP_HDR;
                                        end
                                    end
                                end

                                // Next element: RF settled from prior rf_addr write.
                                CP_DICT_HASH: begin
                                    container_tag_r <= cont_rf_rs1_tag;
                                    container_val_r <= cont_rf_rs1_val;
                                    if (!pycore_dict_key_tag_ok(cont_rf_rs1_tag)) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        begin
                                            logic [31:0] probe0;
                                            probe0 = pycore_dict_key_hash(
                                                cont_rf_rs1_tag, cont_rf_rs1_val)
                                                & (container_slot_count_r - 32'd1);
                                            container_probe_r   <= probe0;
                                            container_probe_n_r <= 32'd0;
                                            container_dmem_addr_r <= pycore_set_tag_addr(
                                                container_buf_r, probe0);
                                        end
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_PROBE;
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_BUILD_SET

                        CONT_SET_ADD: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (cont_rs1_tag != PY_TAG_SET) begin
                                        container_type_trap_r <= 1'b1;
                                    end else if (!pycore_dict_key_tag_ok(cont_rs2_tag)) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        container_tag_r <= cont_rs2_tag;
                                        container_val_r <= cont_rs2_val;
                                        container_insert_new_r  <= 1'b0;
                                        container_finishing_r   <= 1'b0;
                                        container_tomb_valid_r  <= 1'b0;
                                        container_tomb_idx_r    <= 32'd0;
                                        container_base_r         <= cont_rs1_addr;
                                        container_dmem_addr_r    <= cont_rs1_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
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
                                                pycore_set_table_ptr_addr(container_base_r);
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
                                                pycore_trap_recoverable(PY_TRAP_SET_GROW)) begin
                                                trap_marshal_pending_r     <= 1'b1;
                                                trap_marshal_code_r        <= PY_TRAP_SET_GROW;
                                                trap_marshal_entry_count_r <= 3'd2;
                                                trap_marshal_entries_r[0]  <= rs1_r;
                                                trap_marshal_entries_r[1]  <= rs2_r;
                                                container_phase_r          <= CP_DONE;
                                            end else begin
                                                container_set_grow_trap_r <= 1'b1;
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
                                                    pycore_set_tag_addr(
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
                                                if (cont_set_needs_grow) begin
                                                    if (EXCORE_EN &&
                                                        pycore_trap_recoverable(
                                                            PY_TRAP_SET_GROW)) begin
                                                        trap_marshal_pending_r     <= 1'b1;
                                                        trap_marshal_code_r        <=
                                                            PY_TRAP_SET_GROW;
                                                        trap_marshal_entry_count_r <= 3'd2;
                                                        trap_marshal_entries_r[0]  <= rs1_r;
                                                        trap_marshal_entries_r[1]  <= rs2_r;
                                                        container_phase_r          <= CP_DONE;
                                                    end else begin
                                                        container_set_grow_trap_r <= 1'b1;
                                                    end
                                                end else begin
                                                    container_probe_r      <=
                                                        container_tomb_idx_r;
                                                    container_insert_new_r <= 1'b1;
                                                    container_dmem_addr_r  <=
                                                        pycore_set_val_addr(
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
                                                        PY_TRAP_SET_GROW)) begin
                                                    trap_marshal_pending_r     <= 1'b1;
                                                    trap_marshal_code_r        <=
                                                        PY_TRAP_SET_GROW;
                                                    trap_marshal_entry_count_r <= 3'd2;
                                                    trap_marshal_entries_r[0]  <= rs1_r;
                                                    trap_marshal_entries_r[1]  <= rs2_r;
                                                    container_phase_r          <= CP_DONE;
                                                end else begin
                                                    container_set_grow_trap_r <= 1'b1;
                                                end
                                            end
                                        end else begin
                                            container_probe_n_r <= container_probe_n_r + 32'd1;
                                            if (container_rd_data_r[3:0] == PY_TAG_UNINIT) begin
                                                if (cont_set_needs_grow) begin
                                                    if (EXCORE_EN &&
                                                        pycore_trap_recoverable(
                                                            PY_TRAP_SET_GROW)) begin
                                                        trap_marshal_pending_r     <= 1'b1;
                                                        trap_marshal_code_r        <=
                                                            PY_TRAP_SET_GROW;
                                                        trap_marshal_entry_count_r <= 3'd2;
                                                        trap_marshal_entries_r[0]  <= rs1_r;
                                                        trap_marshal_entries_r[1]  <= rs2_r;
                                                        container_phase_r          <= CP_DONE;
                                                    end else begin
                                                        container_set_grow_trap_r <= 1'b1;
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
                                                            pycore_set_val_addr(
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
                                                        pycore_set_tag_addr(
                                                            container_buf_r, cont_probe_next);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                end
                                            end else begin
                                                container_probe_tag_r    <=
                                                    container_rd_data_r[3:0];
                                                container_dmem_addr_r    <=
                                                    pycore_set_val_addr(
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
                                            // Already present — pop element only.
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else if (container_probe_n_r
                                                     >= container_slot_count_r) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_probe_r <= cont_probe_next;
                                            container_dmem_addr_r <= pycore_set_tag_addr(
                                                container_buf_r, cont_probe_next);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_PROBE;
                                        end
                                    end
                                end

                                CP_DICT_WR_KVAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_set_tag_addr(
                                            container_buf_r, container_probe_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_WR_KTAG;
                                    end
                                end

                                CP_DICT_WR_KTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= container_base_r;
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= pycore_set_header(
                                            {32'b0, container_slot_count_r},
                                            container_used_r + 64'd1);
                                        container_dmem_pending_r <= 1'b1;
                                        container_used_r       <= container_used_r + 64'd1;
                                        container_finishing_r  <= 1'b1;
                                        container_phase_r <= CP_HDR;
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_SET_ADD

                        CONT_CONTAINS_SET: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (!pycore_dict_key_tag_ok(cont_rs1_tag)) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        container_tag_r <= cont_rs1_tag;
                                        container_val_r <= cont_rs1_val;
                                        container_base_r         <= cont_rs2_addr;
                                        container_dmem_addr_r    <= cont_rs2_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        container_slot_count_r <= cont_dict_hdr_slots[31:0];
                                        container_used_r       <= cont_dict_hdr_used;
                                        container_dmem_addr_r <=
                                            pycore_set_table_ptr_addr(container_base_r);
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
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                 cur_arg_r[0]});
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            begin
                                                logic [31:0] probe0;
                                                probe0 = pycore_dict_key_hash(
                                                    container_tag_r, container_val_r)
                                                    & (container_slot_count_r - 32'd1);
                                                container_probe_r   <= probe0;
                                                container_probe_n_r <= 32'd0;
                                                container_dmem_addr_r <=
                                                    pycore_set_tag_addr(
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
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                 cur_arg_r[0]});
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            container_probe_n_r <= container_probe_n_r + 32'd1;
                                            if (container_rd_data_r[3:0] == PY_TAG_UNINIT) begin
                                                container_wb_we_r   <= 1'b1;
                                                container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                                container_wb_data_r <= pycore_make_entry(
                                                    PY_TAG_BOOL,
                                                    {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                     cur_arg_r[0]});
                                                tos_r             <= tos_r - RF_AW'(1);
                                                fetch_skip_r      <= 1'b1;
                                                container_phase_r <= CP_DONE;
                                            end else if (pycore_dict_tombstone(
                                                            container_rd_data_r[3:0])) begin
                                                if (container_probe_n_r + 32'd1
                                                        >= container_slot_count_r) begin
                                                    container_wb_we_r   <= 1'b1;
                                                    container_wb_addr_r <=
                                                        RF_AW'(tos_r - RF_AW'(2));
                                                    container_wb_data_r <= pycore_make_entry(
                                                        PY_TAG_BOOL,
                                                        {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                         cur_arg_r[0]});
                                                    tos_r             <= tos_r - RF_AW'(1);
                                                    fetch_skip_r      <= 1'b1;
                                                    container_phase_r <= CP_DONE;
                                                end else begin
                                                    container_probe_r <= cont_probe_next;
                                                    container_dmem_addr_r <=
                                                        pycore_set_tag_addr(
                                                            container_buf_r, cont_probe_next);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                end
                                            end else begin
                                                container_probe_tag_r    <=
                                                    container_rd_data_r[3:0];
                                                container_dmem_addr_r    <=
                                                    pycore_set_val_addr(
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
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                 ~cur_arg_r[0]});
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else if (container_probe_n_r
                                                     >= container_slot_count_r) begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                 cur_arg_r[0]});
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            container_probe_r <= cont_probe_next;
                                            container_dmem_addr_r <= pycore_set_tag_addr(
                                                container_buf_r, cont_probe_next);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_PROBE;
                                        end
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_CONTAINS_SET

                        CONT_SET_UPDATE: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (cont_rs1_tag != PY_TAG_SET) begin
                                        container_type_trap_r <= 1'b1;
                                    end else if (EXCORE_EN &&
                                                 pycore_trap_recoverable(
                                                     PY_TRAP_SET_UPDATE)) begin
                                        trap_marshal_pending_r     <= 1'b1;
                                        trap_marshal_code_r        <= PY_TRAP_SET_UPDATE;
                                        trap_marshal_entry_count_r <= 3'd2;
                                        trap_marshal_entries_r[0]  <= rs1_r;
                                        trap_marshal_entries_r[1]  <= rs2_r;
                                        container_phase_r          <= CP_DONE;
                                    end else begin
                                        container_set_update_trap_r <= 1'b1;
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_SET_UPDATE

