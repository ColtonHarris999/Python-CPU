// pycore_cont_bulk.svh — bulk DICT_UPDATE / DICT_MERGE / SET_UPDATE arms of
// S_CONTAINER. Included inside pycore_core's unique case (container_op_r); do
// not compile alone.
//
// Two families of behaviour live here:
//   * Uncontaminated LIST/SET/DICT sources are handed to excore as a single
//     trap (the historical fast path — unchanged routing).
//   * Contaminated (OBJECT key/element) sources and every TUPLE source are
//     owned end-to-end by pycore: optionally grow the destination table in
//     place (rehash), then fold every source element in with the SET_ADD /
//     STORE_DICT probe. A shared probe/insert sub-FSM (CP_DICT_PROBE …
//     CP_DICT_WR_KTAG) is reused for both the rehash relocation and the
//     source-element inserts, dispatched by container_bulk_mode_r.
//
// Phase-code reuse: each container op owns its own phase case table, so the
// CP_* names below carry op-local meaning (documented inline) rather than the
// dict/list meaning they have elsewhere.

                        // =====================================================
                        // SET_UPDATE — A.update(iterable B). A = rs1 at
                        // RF[tos-1-arg]; B = rs2 at TOS; pop B.
                        //   col_excore(B) = LIST | SET | DICT (NOT TUPLE).
                        //   con(x)        = MUT_COLLEC contamination bit.
                        // Uncontaminated col_excore(B) → one excore trap.
                        // Otherwise pycore: (maybe) grow+rehash A, then insert
                        // every element of B (SET_ADD-style, dups skipped).
                        // =====================================================
                        CONT_SET_UPDATE: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (!pycore_is_set(cont_rs1_tag, cont_rs1_val)) begin
                                        container_type_trap_r <= 1'b1;
                                    end else if (!(pycore_is_list(cont_rs2_tag, cont_rs2_val) ||
                                                   pycore_is_set(cont_rs2_tag, cont_rs2_val) ||
                                                   pycore_is_dict(cont_rs2_tag, cont_rs2_val) ||
                                                   (cont_rs2_tag == PY_TAG_TUPLE))) begin
                                        // Unsupported iterable type.
                                        container_type_trap_r <= 1'b1;
                                    end else if (!cont_rs1_contam && !cont_rs2_contam &&
                                                 (pycore_is_list(cont_rs2_tag, cont_rs2_val) ||
                                                  pycore_is_set(cont_rs2_tag, cont_rs2_val) ||
                                                  pycore_is_dict(cont_rs2_tag, cont_rs2_val)) &&
                                                 EXCORE_EN &&
                                                 pycore_trap_recoverable(
                                                     PY_TRAP_SET_UPDATE)) begin
                                        // Uncontaminated LIST/SET/DICT source:
                                        // excore inserts all elements, pop 1.
                                        trap_marshal_pending_r     <= 1'b1;
                                        trap_marshal_code_r        <= PY_TRAP_SET_UPDATE;
                                        trap_marshal_entry_count_r <= 3'd2;
                                        trap_marshal_entries_r[0]  <= rs1_r;
                                        trap_marshal_entries_r[1]  <= rs2_r;
                                        container_phase_r          <= CP_DONE;
                                    end else begin
                                        // pycore bulk path: TUPLE source (always)
                                        // or any contaminated operand.
                                        container_base_r   <= cont_rs1_addr;
                                        container_contam_r <= cont_rs2_contam;
                                        // Source kind + dense-walk sizing.
                                        if (cont_rs2_tag == PY_TAG_TUPLE) begin
                                            container_src_kind_r  <= BULK_SRC_TUPLE;
                                            container_src_base_r  <= cont_rs2_val[31:0];
                                            container_bulk_size_r <=
                                                pycore_tuple_size(cont_rs2_val);
                                            container_src_slots_r <=
                                                pycore_tuple_size(cont_rs2_val);
                                        end else if (pycore_is_list(cont_rs2_tag,
                                                                    cont_rs2_val)) begin
                                            container_src_kind_r <= BULK_SRC_LIST;
                                            container_src_base_r <= cont_rs2_addr;
                                        end else if (pycore_is_set(cont_rs2_tag,
                                                                   cont_rs2_val)) begin
                                            container_src_kind_r <= BULK_SRC_SET;
                                            container_src_base_r <= cont_rs2_addr;
                                        end else begin
                                            container_src_kind_r <= BULK_SRC_DICT;
                                            container_src_base_r <= cont_rs2_addr;
                                        end
                                        // con(B) → contaminate A's handle before
                                        // touching any element (minimise traps).
                                        if (cont_rs2_contam) begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(
                                                {2'b0, tos_r} - 9'd1
                                                - {2'b0, cur_arg_r[6:0]});
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_MUT_COLLEC,
                                                pycore_mut_set_contaminated(cont_rs1_val));
                                        end
                                        // Read A's set header (slots, used).
                                        container_dmem_addr_r    <= cont_rs1_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
                                    end
                                end

                                // A header acked → slots/used; read table_ptr.
                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        container_slot_count_r <= cont_dict_hdr_slots[31:0];
                                        container_used_r       <= cont_dict_hdr_used;
                                        container_dmem_addr_r  <=
                                            pycore_set_table_ptr_addr(container_base_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_LIST_BUF;
                                    end
                                end

                                // A table_ptr acked → save old table; gather B
                                // metadata (TUPLE needs none).
                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        container_old_table_r <= cont_dict_table_ptr;
                                        container_old_slots_r <= container_slot_count_r;
                                        if (container_src_kind_r == BULK_SRC_TUPLE) begin
                                            container_phase_r <= CP_BULK_SRC_HDR;
                                        end else begin
                                            container_dmem_addr_r    <= container_src_base_r;
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_SRC_HDR;
                                        end
                                    end
                                end

                                // B header acked → size + walk bound; read the
                                // source buffer / table pointer.
                                CP_SRC_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_src_kind_r == BULK_SRC_LIST) begin
                                            container_bulk_size_r <=
                                                pycore_list_length(container_rd_data_r);
                                            container_src_slots_r <=
                                                pycore_list_length(container_rd_data_r);
                                            container_dmem_addr_r <=
                                                pycore_list_obitem_addr(container_src_base_r);
                                        end else if (container_src_kind_r == BULK_SRC_SET) begin
                                            container_bulk_size_r <=
                                                pycore_dict_used_from_hdr(container_rd_data_r);
                                            container_src_slots_r <=
                                                pycore_dict_slot_count_from_hdr(
                                                    container_rd_data_r);
                                            container_dmem_addr_r <=
                                                pycore_set_table_ptr_addr(container_src_base_r);
                                        end else begin // BULK_SRC_DICT
                                            container_bulk_size_r <=
                                                pycore_dict_used_from_hdr(container_rd_data_r);
                                            container_src_slots_r <=
                                                pycore_dict_slot_count_from_hdr(
                                                    container_rd_data_r);
                                            container_dmem_addr_r <=
                                                pycore_dict_table_ptr_addr(container_src_base_r);
                                        end
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_BULK_RD_KEY;
                                    end
                                end

                                // B buffer/table ptr acked → source base.
                                CP_BULK_RD_KEY: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_src_kind_r == BULK_SRC_LIST)
                                            container_src_base_r <=
                                                pycore_list_obitem(container_rd_data_r);
                                        else
                                            container_src_base_r <= container_rd_data_r[31:0];
                                        container_phase_r <= CP_BULK_SRC_HDR;
                                    end
                                end

                                // Resize decision (no dmem). Either grow+rehash
                                // A into a fresh table, or insert into place.
                                CP_BULK_SRC_HDR: begin
                                    begin
                                        logic [63:0] need;
                                        logic [31:0] new_slots;
                                        need = container_used_r + container_bulk_size_r;
                                        if (pycore_set_needs_grow(
                                                need, {32'b0, container_slot_count_r})) begin
                                            new_slots = pycore_dict_grow_slots(
                                                need, container_slot_count_r);
                                            if ((heap_ptr_r + (new_slots << 5))
                                                    > PYCORE_HEAP_LIMIT) begin
                                                container_mem_fault_r <= 1'b1;
                                            end else begin
                                                container_buf_r        <= heap_ptr_r;
                                                heap_ptr_r             <=
                                                    heap_ptr_r + (new_slots << 5);
                                                container_slot_count_r <= new_slots;
                                                container_bulk_mode_r  <= BULK_MODE_REHASH;
                                                container_src_idx_r    <= 32'd0;
                                                // First old-table slot tag read.
                                                container_dmem_addr_r  <=
                                                    pycore_set_tag_addr(
                                                        container_old_table_r, 32'd0);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r        <= CP_BULK_SCAN;
                                            end
                                        end else begin
                                            container_buf_r       <= container_old_table_r;
                                            container_bulk_mode_r <= BULK_MODE_INSERT;
                                            container_src_idx_r   <= 32'd0;
                                            container_phase_r     <= CP_BULK_INS;
                                        end
                                    end
                                end

                                // Rehash scanner: old-table slot tag acked.
                                CP_BULK_SCAN: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_src_idx_r >= container_old_slots_r) begin
                                            // Rehash done → publish new table_ptr.
                                            container_dmem_addr_r <=
                                                pycore_set_table_ptr_addr(container_base_r);
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <=
                                                {64'd0, {32'b0, container_buf_r}};
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_COPY_VAL_WB;
                                        end else if (pycore_dict_slot_empty(
                                                         container_rd_data_r) ||
                                                     pycore_dict_tombstone(
                                                         container_rd_data_r[3:0])) begin
                                            // Skip empty / tombstone slot.
                                            container_src_idx_r <= container_src_idx_r + 32'd1;
                                            if ((container_src_idx_r + 32'd1) >=
                                                    container_old_slots_r) begin
                                                container_dmem_addr_r <=
                                                    pycore_set_table_ptr_addr(container_base_r);
                                                container_dmem_we_r    <= 1'b1;
                                                container_dmem_wdata_r <=
                                                    {64'd0, {32'b0, container_buf_r}};
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r <= CP_COPY_VAL_WB;
                                            end else begin
                                                container_dmem_addr_r <= pycore_set_tag_addr(
                                                    container_old_table_r,
                                                    container_src_idx_r + 32'd1);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                            end
                                        end else begin
                                            // Occupied: capture tag, read value.
                                            container_tag_r <= container_rd_data_r[3:0];
                                            container_dmem_addr_r <= pycore_set_val_addr(
                                                container_old_table_r, container_src_idx_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_BULK_RD_VAL;
                                        end
                                    end
                                end

                                // Old element value acked → enter insert probe.
                                CP_BULK_RD_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        logic [31:0] probe0;
                                        container_val_r <= container_rd_data_r;
                                        probe0 = pycore_dict_key_hash(
                                                     container_tag_r, container_rd_data_r)
                                                 & (container_slot_count_r - 32'd1);
                                        container_probe_r      <= probe0;
                                        container_probe_n_r    <= 32'd0;
                                        container_tomb_valid_r <= 1'b0;
                                        container_dmem_addr_r  <= pycore_set_tag_addr(
                                            container_buf_r, probe0);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_DICT_PROBE;
                                    end
                                end

                                // Shared insert probe: target-table slot tag acked.
                                CP_DICT_PROBE: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_probe_n_r >= container_slot_count_r) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_probe_n_r <= container_probe_n_r + 32'd1;
                                            if (pycore_dict_slot_empty(
                                                    container_rd_data_r)) begin
                                                logic [31:0] ins;
                                                ins = container_tomb_valid_r ?
                                                      container_tomb_idx_r : container_probe_r;
                                                container_probe_r      <= ins;
                                                container_insert_new_r <= 1'b1;
                                                container_dmem_addr_r  <= pycore_set_val_addr(
                                                    container_buf_r, ins);
                                                container_dmem_we_r    <= 1'b1;
                                                container_dmem_wdata_r <= container_val_r;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r <= CP_DICT_WR_KVAL;
                                            end else if (pycore_dict_tombstone(
                                                            container_rd_data_r[3:0])) begin
                                                if (!container_tomb_valid_r) begin
                                                    container_tomb_valid_r <= 1'b1;
                                                    container_tomb_idx_r   <= container_probe_r;
                                                end
                                                container_probe_r <= cont_probe_next;
                                                container_dmem_addr_r <= pycore_set_tag_addr(
                                                    container_buf_r, cont_probe_next);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                            end else begin
                                                container_probe_tag_r <= container_rd_data_r[3:0];
                                                container_dmem_addr_r <= pycore_set_val_addr(
                                                    container_buf_r, container_probe_r);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r <= CP_DICT_CHK_VAL;
                                            end
                                        end
                                    end
                                end

                                // Occupied slot value acked → duplicate check.
                                CP_DICT_CHK_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_dict_key_match) begin
                                            // Duplicate — skip insert, continue.
                                            // (REHASH never dups: A holds unique
                                            //  elements and the target is fresh.)
                                            if (container_bulk_mode_r == BULK_MODE_REHASH) begin
                                                container_src_idx_r <=
                                                    container_src_idx_r + 32'd1;
                                                if ((container_src_idx_r + 32'd1) >=
                                                        container_old_slots_r) begin
                                                    container_dmem_addr_r <=
                                                        pycore_set_table_ptr_addr(
                                                            container_base_r);
                                                    container_dmem_we_r    <= 1'b1;
                                                    container_dmem_wdata_r <=
                                                        {64'd0, {32'b0, container_buf_r}};
                                                    container_dmem_pending_r <= 1'b1;
                                                    container_phase_r <= CP_COPY_VAL_WB;
                                                end else begin
                                                    container_dmem_addr_r <=
                                                        pycore_set_tag_addr(
                                                            container_old_table_r,
                                                            container_src_idx_r + 32'd1);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                    container_phase_r <= CP_BULK_SCAN;
                                                end
                                            end else begin
                                                container_src_idx_r <=
                                                    container_src_idx_r + 32'd1;
                                                container_phase_r <= CP_BULK_INS;
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

                                // Element value written → write element tag.
                                CP_DICT_WR_KVAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_set_tag_addr(
                                            container_buf_r, container_probe_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= pycore_dict_key_tag_word(
                                            container_tag_r, container_val_r);
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_WR_KTAG;
                                    end
                                end

                                // Element tag written → post-insert continuation.
                                CP_DICT_WR_KTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_insert_new_r <= 1'b0;
                                        if (container_bulk_mode_r == BULK_MODE_REHASH) begin
                                            container_src_idx_r <=
                                                container_src_idx_r + 32'd1;
                                            if ((container_src_idx_r + 32'd1) >=
                                                    container_old_slots_r) begin
                                                container_dmem_addr_r <=
                                                    pycore_set_table_ptr_addr(
                                                        container_base_r);
                                                container_dmem_we_r    <= 1'b1;
                                                container_dmem_wdata_r <=
                                                    {64'd0, {32'b0, container_buf_r}};
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r <= CP_COPY_VAL_WB;
                                            end else begin
                                                container_dmem_addr_r <=
                                                    pycore_set_tag_addr(
                                                        container_old_table_r,
                                                        container_src_idx_r + 32'd1);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r <= CP_BULK_SCAN;
                                            end
                                        end else begin
                                            container_used_r    <= container_used_r + 64'd1;
                                            container_src_idx_r <= container_src_idx_r + 32'd1;
                                            container_phase_r   <= CP_BULK_INS;
                                        end
                                    end
                                end

                                // New table_ptr published → begin the B walk.
                                CP_COPY_VAL_WB: begin
                                    if (!container_dmem_pending_r) begin
                                        container_bulk_mode_r <= BULK_MODE_INSERT;
                                        container_src_idx_r   <= 32'd0;
                                        container_phase_r     <= CP_BULK_INS;
                                    end
                                end

                                // B-walk dispatcher: fetch next source element.
                                CP_BULK_INS: begin
                                    if (container_src_idx_r >= container_src_slots_r) begin
                                        // Done: commit A header (slots, used).
                                        container_dmem_addr_r  <= container_base_r;
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= pycore_set_header(
                                            {32'b0, container_slot_count_r}, container_used_r);
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_TAG;
                                    end else if ((container_src_kind_r == BULK_SRC_LIST) ||
                                                 (container_src_kind_r == BULK_SRC_TUPLE)) begin
                                        // Dense: read element value.
                                        container_dmem_addr_r <= container_src_base_r +
                                            (container_src_idx_r << 5);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_NAME_VAL;
                                    end else if (container_src_kind_r == BULK_SRC_SET) begin
                                        // Sparse set: read slot tag.
                                        container_dmem_addr_r <= pycore_set_tag_addr(
                                            container_src_base_r, container_src_idx_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_NAME_TAG;
                                    end else begin // BULK_SRC_DICT
                                        // Sparse dict: read key tag (stride 64).
                                        container_dmem_addr_r <= pycore_dict_ktag_addr(
                                            container_src_base_r, container_src_idx_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_RD_VVAL;
                                    end
                                end

                                // Dense element value acked → read element tag.
                                CP_NAME_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <= container_src_base_r +
                                            (container_src_idx_r << 5) + 32'd16;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_RD_VTAG;
                                    end
                                end

                                // Dense element tag acked → validate + insert.
                                CP_DICT_RD_VTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        if (!pycore_dict_key_tag_ok(
                                                container_rd_data_r[3:0])) begin
                                            container_type_trap_r <= 1'b1;
                                        end else begin
                                            logic [31:0] probe0;
                                            if (container_rd_data_r[3:0] == PY_TAG_OBJECT)
                                                container_contam_r <= 1'b1;
                                            container_tag_r <= container_rd_data_r[3:0];
                                            probe0 = pycore_dict_key_hash(
                                                         container_rd_data_r[3:0],
                                                         container_val_r)
                                                     & (container_slot_count_r - 32'd1);
                                            container_probe_r      <= probe0;
                                            container_probe_n_r    <= 32'd0;
                                            container_tomb_valid_r <= 1'b0;
                                            container_dmem_addr_r  <= pycore_set_tag_addr(
                                                container_buf_r, probe0);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_DICT_PROBE;
                                        end
                                    end
                                end

                                // Sparse set slot tag acked → skip or read value.
                                CP_NAME_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        if (pycore_dict_slot_empty(container_rd_data_r) ||
                                            pycore_dict_tombstone(
                                                container_rd_data_r[3:0])) begin
                                            container_src_idx_r <= container_src_idx_r + 32'd1;
                                            container_phase_r   <= CP_BULK_INS;
                                        end else begin
                                            container_tag_r <= container_rd_data_r[3:0];
                                            container_dmem_addr_r <= pycore_set_val_addr(
                                                container_src_base_r, container_src_idx_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_RANGE_START_VAL;
                                        end
                                    end
                                end

                                // Sparse set element value acked → insert.
                                CP_RANGE_START_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        logic [31:0] probe0;
                                        container_val_r <= container_rd_data_r;
                                        if (container_tag_r == PY_TAG_OBJECT)
                                            container_contam_r <= 1'b1;
                                        probe0 = pycore_dict_key_hash(
                                                     container_tag_r, container_rd_data_r)
                                                 & (container_slot_count_r - 32'd1);
                                        container_probe_r      <= probe0;
                                        container_probe_n_r    <= 32'd0;
                                        container_tomb_valid_r <= 1'b0;
                                        container_dmem_addr_r  <= pycore_set_tag_addr(
                                            container_buf_r, probe0);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_DICT_PROBE;
                                    end
                                end

                                // Sparse dict key tag acked → skip or read key val.
                                CP_DICT_RD_VVAL: begin
                                    if (!container_dmem_pending_r) begin
                                        if (pycore_dict_slot_empty(container_rd_data_r) ||
                                            pycore_dict_tombstone(
                                                container_rd_data_r[3:0])) begin
                                            container_src_idx_r <= container_src_idx_r + 32'd1;
                                            container_phase_r   <= CP_BULK_INS;
                                        end else begin
                                            container_tag_r <= container_rd_data_r[3:0];
                                            container_dmem_addr_r <= pycore_dict_kval_addr(
                                                container_src_base_r, container_src_idx_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_RANGE_STOP_VAL;
                                        end
                                    end
                                end

                                // Sparse dict key value acked → insert key.
                                CP_RANGE_STOP_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        logic [31:0] probe0;
                                        container_val_r <= container_rd_data_r;
                                        if (container_tag_r == PY_TAG_OBJECT)
                                            container_contam_r <= 1'b1;
                                        probe0 = pycore_dict_key_hash(
                                                     container_tag_r, container_rd_data_r)
                                                 & (container_slot_count_r - 32'd1);
                                        container_probe_r      <= probe0;
                                        container_probe_n_r    <= 32'd0;
                                        container_tomb_valid_r <= 1'b0;
                                        container_dmem_addr_r  <= pycore_set_tag_addr(
                                            container_buf_r, probe0);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_DICT_PROBE;
                                    end
                                end

                                // A header committed → contaminate handle + pop.
                                CP_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_contam_r) begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(
                                                {2'b0, tos_r} - 9'd1
                                                - {2'b0, cur_arg_r[6:0]});
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_MUT_COLLEC,
                                                pycore_mut_set_contaminated(cont_rs1_val));
                                        end
                                        tos_r             <= tos_r - RF_AW'(1);
                                        fetch_skip_r      <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_SET_UPDATE

                        // =====================================================
                        // DICT_UPDATE — A.update(B), both MUT_DICT. A = rs1 at
                        // RF[tos-1-arg]; B = rs2 at TOS; pop B.
                        // Uncontaminated → one excore trap. Contaminated (OBJECT
                        // keys on either side) → pycore grow+rehash A then fold
                        // in every key/value of B (overwrite on duplicate).
                        // =====================================================
                        CONT_DICT_UPDATE: begin
                            unique case (container_phase_r)
                                CP_INIT: begin
                                    if (!pycore_is_dict(cont_rs1_tag, cont_rs1_val) ||
                                        !pycore_is_dict(cont_rs2_tag, cont_rs2_val)) begin
                                        container_type_trap_r <= 1'b1;
                                    end else if (!cont_rs1_contam && !cont_rs2_contam &&
                                                 EXCORE_EN &&
                                                 pycore_trap_recoverable(
                                                     PY_TRAP_DICT_UPDATE)) begin
                                        // Uncontaminated: excore does the whole
                                        // grow-to-fit + insert-all, pop 1 (source).
                                        trap_marshal_pending_r     <= 1'b1;
                                        trap_marshal_code_r        <= PY_TRAP_DICT_UPDATE;
                                        trap_marshal_entry_count_r <= 3'd2;
                                        trap_marshal_entries_r[0]  <= rs1_r;
                                        trap_marshal_entries_r[1]  <= rs2_r;
                                        container_phase_r          <= CP_DONE;
                                    end else begin
                                        // Contaminated: pycore owns the update.
                                        container_base_r        <= cont_rs1_addr;
                                        container_src_base_r     <= cont_rs2_addr;
                                        container_contam_r       <= cont_rs1_contam |
                                                                    cont_rs2_contam;
                                        container_dst_rf_addr_r  <=
                                            {2'b0, tos_r} - 9'd1 - {2'b0, cur_arg_r[6:0]};
                                        if (cont_rs2_contam) begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(
                                                {2'b0, tos_r} - 9'd1
                                                - {2'b0, cur_arg_r[6:0]});
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_MUT_COLLEC,
                                                pycore_mut_set_contaminated(cont_rs1_val));
                                        end
                                        container_dmem_addr_r    <= cont_rs1_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
                                    end
                                end

                                // A header acked → slots/used; read A meta.
                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        container_slot_count_r <= cont_dict_hdr_slots[31:0];
                                        container_old_slots_r  <= cont_dict_hdr_slots[31:0];
                                        container_used_r       <= cont_dict_hdr_used;
                                        container_dmem_addr_r  <=
                                            pycore_dict_meta_addr(container_base_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_DICT_META;
                                    end
                                end

                                // A meta acked → version/order_len; read A ptr.
                                CP_DICT_META: begin
                                    if (!container_dmem_pending_r) begin
                                        container_order_len_r <=
                                            pycore_dict_order_len_from_meta(container_rd_data_r);
                                        container_dict_version_r <=
                                            pycore_dict_version_from_meta(container_rd_data_r);
                                        container_dmem_addr_r <=
                                            pycore_dict_table_ptr_addr(container_base_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_LIST_BUF;
                                    end
                                end

                                // A packed ptr acked → old table/order; read B hdr.
                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        container_old_table_r <= cont_dict_table_ptr;
                                        container_old_order_r <= cont_dict_order_ptr;
                                        container_dmem_addr_r    <= container_src_base_r;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_SRC_HDR;
                                    end
                                end

                                // B header acked → usedB/B slots; read B ptr.
                                CP_SRC_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        container_bulk_size_r <=
                                            pycore_dict_used_from_hdr(container_rd_data_r);
                                        container_src_slots_r <=
                                            pycore_dict_slot_count_from_hdr(container_rd_data_r);
                                        container_dmem_addr_r <=
                                            pycore_dict_table_ptr_addr(container_src_base_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_BULK_RD_KEY;
                                    end
                                end

                                // B packed ptr acked → B table base.
                                CP_BULK_RD_KEY: begin
                                    if (!container_dmem_pending_r) begin
                                        container_src_base_r <= container_rd_data_r[31:0];
                                        container_phase_r    <= CP_BULK_SRC_HDR;
                                    end
                                end

                                // Resize decision: grow (order-copy + rehash) or
                                // insert into place.
                                CP_BULK_SRC_HDR: begin
                                    begin
                                        logic [63:0] need;
                                        logic [31:0] new_slots;
                                        logic [31:0] ord_bytes;
                                        logic [31:0] tbl_bytes;
                                        need = container_used_r + container_bulk_size_r;
                                        if (pycore_dict_needs_grow(
                                                need, {32'b0, container_slot_count_r})) begin
                                            new_slots = pycore_dict_grow_slots(
                                                need, container_slot_count_r);
                                            ord_bytes = new_slots << 5;
                                            tbl_bytes = new_slots << 6;
                                            if ((heap_ptr_r + ord_bytes + tbl_bytes)
                                                    > PYCORE_HEAP_LIMIT) begin
                                                container_mem_fault_r <= 1'b1;
                                            end else begin
                                                container_order_ptr_r  <= heap_ptr_r;
                                                container_buf_r        <= heap_ptr_r + ord_bytes;
                                                heap_ptr_r             <=
                                                    heap_ptr_r + ord_bytes + tbl_bytes;
                                                container_slot_count_r <= new_slots;
                                                container_bulk_mode_r  <= BULK_MODE_REHASH;
                                                container_src_idx_r    <= 32'd0;
                                                if (container_order_len_r == 64'd0) begin
                                                    // Nothing to copy/rehash.
                                                    container_phase_r <= CP_BULK_SCAN;
                                                end else begin
                                                    container_dmem_addr_r <=
                                                        pycore_dict_order_val_addr(
                                                            container_old_order_r, 32'd0);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                    container_phase_r <= CP_DICT_ORDER_SCAN_VAL;
                                                end
                                            end
                                        end else begin
                                            container_order_ptr_r <= container_old_order_r;
                                            container_buf_r       <= container_old_table_r;
                                            container_bulk_mode_r <= BULK_MODE_INSERT;
                                            container_src_idx_r   <= 32'd0;
                                            container_phase_r     <= CP_BULK_INS;
                                        end
                                    end
                                end

                                // ---- Order-buffer copy (grow only) -------------
                                CP_DICT_ORDER_SCAN_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <= pycore_dict_order_tag_addr(
                                            container_old_order_r, container_src_idx_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_DICT_ORDER_SCAN_TAG;
                                    end
                                end
                                CP_DICT_ORDER_SCAN_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_tag_r <= container_rd_data_r[3:0];
                                        container_dmem_addr_r <= pycore_dict_order_val_addr(
                                            container_order_ptr_r, container_src_idx_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= container_val_r;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_ORDER_SHIFT_VAL_WR;
                                    end
                                end
                                CP_DICT_ORDER_SHIFT_VAL_WR: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r <= pycore_dict_order_tag_addr(
                                            container_order_ptr_r, container_src_idx_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_ORDER_SHIFT_TAG_WR;
                                    end
                                end
                                CP_DICT_ORDER_SHIFT_TAG_WR: begin
                                    if (!container_dmem_pending_r) begin
                                        if ((container_src_idx_r + 32'd1) >=
                                                container_order_len_r[31:0]) begin
                                            // Order copy done → start table rehash.
                                            container_src_idx_r <= 32'd0;
                                            container_phase_r   <= CP_BULK_SCAN;
                                        end else begin
                                            container_src_idx_r <= container_src_idx_r + 32'd1;
                                            container_dmem_addr_r <= pycore_dict_order_val_addr(
                                                container_old_order_r,
                                                container_src_idx_r + 32'd1);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_ORDER_SCAN_VAL;
                                        end
                                    end
                                end

                                // ---- Rehash dispatch (grow only) ---------------
                                // CP_BULK_SCAN issues; CP_DICT_ORDER_FINAL processes.
                                CP_BULK_SCAN: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_src_idx_r >= container_old_slots_r) begin
                                            // Rehash done → publish new packed ptr.
                                            container_dmem_addr_r <=
                                                pycore_dict_table_ptr_addr(container_base_r);
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <= {
                                                32'b0, container_order_ptr_r,
                                                32'b0, container_buf_r};
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_LIST_WB;
                                        end else begin
                                            container_dmem_addr_r <= pycore_dict_ktag_addr(
                                                container_old_table_r, container_src_idx_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_ORDER_FINAL;
                                        end
                                    end
                                end
                                CP_DICT_ORDER_FINAL: begin
                                    if (!container_dmem_pending_r) begin
                                        if (pycore_dict_slot_empty(container_rd_data_r) ||
                                            pycore_dict_tombstone(
                                                container_rd_data_r[3:0])) begin
                                            container_src_idx_r <= container_src_idx_r + 32'd1;
                                            container_phase_r   <= CP_BULK_SCAN;
                                        end else begin
                                            container_tag_r <= container_rd_data_r[3:0];
                                            container_dmem_addr_r <= pycore_dict_kval_addr(
                                                container_old_table_r, container_src_idx_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_BULK_RD_VAL;
                                        end
                                    end
                                end
                                CP_LIST_WB: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= container_base_r;
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= pycore_dict_header(
                                            {32'b0, container_slot_count_r}, container_used_r);
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_COPY_TAG_WB;
                                    end
                                end
                                CP_COPY_TAG_WB: begin
                                    if (!container_dmem_pending_r) begin
                                        container_bulk_mode_r <= BULK_MODE_INSERT;
                                        container_src_idx_r   <= 32'd0;
                                        container_phase_r     <= CP_BULK_INS;
                                    end
                                end

                                // ---- B merge dispatch --------------------------
                                CP_BULK_INS: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_src_idx_r >= container_src_slots_r) begin
                                            // Done → commit A header.
                                            container_dmem_addr_r  <= container_base_r;
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <= pycore_dict_header(
                                                {32'b0, container_slot_count_r},
                                                container_used_r);
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_TAG;
                                        end else begin
                                            container_dmem_addr_r <= pycore_dict_ktag_addr(
                                                container_src_base_r, container_src_idx_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_NAME_TAG;
                                        end
                                    end
                                end
                                CP_NAME_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        if (pycore_dict_slot_empty(container_rd_data_r) ||
                                            pycore_dict_tombstone(
                                                container_rd_data_r[3:0])) begin
                                            container_src_idx_r <= container_src_idx_r + 32'd1;
                                            container_phase_r   <= CP_BULK_INS;
                                        end else begin
                                            container_tag_r <= container_rd_data_r[3:0];
                                            container_dmem_addr_r <= pycore_dict_kval_addr(
                                                container_src_base_r, container_src_idx_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_BULK_RD_VAL;
                                        end
                                    end
                                end

                                // ---- Shared entry read (rehash + merge) --------
                                CP_BULK_RD_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        logic [31:0] stbl;
                                        stbl = (container_bulk_mode_r == BULK_MODE_REHASH) ?
                                               container_old_table_r : container_src_base_r;
                                        container_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <= pycore_dict_vval_addr(
                                            stbl, container_src_idx_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_DICT_RD_VVAL;
                                    end
                                end
                                CP_DICT_RD_VVAL: begin
                                    if (!container_dmem_pending_r) begin
                                        logic [31:0] stbl;
                                        stbl = (container_bulk_mode_r == BULK_MODE_REHASH) ?
                                               container_old_table_r : container_src_base_r;
                                        container_order_shift_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <= pycore_dict_vtag_addr(
                                            stbl, container_src_idx_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_DICT_RD_VTAG;
                                    end
                                end
                                CP_DICT_RD_VTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        logic [31:0] probe0;
                                        container_order_shift_tag_r <= container_rd_data_r[3:0];
                                        probe0 = pycore_dict_key_hash(
                                                     container_tag_r, container_val_r)
                                                 & (container_slot_count_r - 32'd1);
                                        container_probe_r      <= probe0;
                                        container_probe_n_r    <= 32'd0;
                                        container_tomb_valid_r <= 1'b0;
                                        container_dmem_addr_r  <= pycore_dict_ktag_addr(
                                            container_buf_r, probe0);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_DICT_PROBE;
                                    end
                                end

                                // ---- Shared probe/insert into target table -----
                                CP_DICT_PROBE: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_probe_n_r >= container_slot_count_r) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_probe_n_r <= container_probe_n_r + 32'd1;
                                            if (pycore_dict_slot_empty(
                                                    container_rd_data_r)) begin
                                                logic [31:0] ins;
                                                ins = container_tomb_valid_r ?
                                                      container_tomb_idx_r : container_probe_r;
                                                container_probe_r      <= ins;
                                                container_insert_new_r <= 1'b1;
                                                container_dmem_addr_r  <= pycore_dict_kval_addr(
                                                    container_buf_r, ins);
                                                container_dmem_we_r    <= 1'b1;
                                                container_dmem_wdata_r <= container_val_r;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r <= CP_DICT_WR_KVAL;
                                            end else if (pycore_dict_tombstone(
                                                            container_rd_data_r[3:0])) begin
                                                if (!container_tomb_valid_r) begin
                                                    container_tomb_valid_r <= 1'b1;
                                                    container_tomb_idx_r   <= container_probe_r;
                                                end
                                                container_probe_r <= cont_probe_next;
                                                container_dmem_addr_r <= pycore_dict_ktag_addr(
                                                    container_buf_r, cont_probe_next);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                            end else begin
                                                container_probe_tag_r <= container_rd_data_r[3:0];
                                                container_dmem_addr_r <= pycore_dict_kval_addr(
                                                    container_buf_r, container_probe_r);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r <= CP_DICT_CHK_VAL;
                                            end
                                        end
                                    end
                                end
                                CP_DICT_CHK_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_dict_key_match) begin
                                            // Overwrite existing key's value.
                                            container_insert_new_r <= 1'b0;
                                            container_dmem_addr_r  <= pycore_dict_vval_addr(
                                                container_buf_r, container_probe_r);
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <=
                                                container_order_shift_val_r;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_WR_VVAL;
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
                                        container_dmem_wdata_r <= pycore_dict_key_tag_word(
                                            container_tag_r, container_val_r);
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_WR_KTAG;
                                    end
                                end
                                CP_DICT_WR_KTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_dict_vval_addr(
                                            container_buf_r, container_probe_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= container_order_shift_val_r;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_WR_VVAL;
                                    end
                                end
                                CP_DICT_WR_VVAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_dict_vtag_addr(
                                            container_buf_r, container_probe_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <=
                                            {124'b0, container_order_shift_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_WR_VTAG;
                                    end
                                end
                                CP_DICT_WR_VTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_bulk_mode_r == BULK_MODE_REHASH) begin
                                            container_insert_new_r <= 1'b0;
                                            container_src_idx_r <= container_src_idx_r + 32'd1;
                                            container_phase_r   <= CP_BULK_SCAN;
                                        end else if (container_insert_new_r) begin
                                            // New key → append to order buffer.
                                            container_dmem_addr_r <= pycore_dict_order_val_addr(
                                                container_order_ptr_r,
                                                container_order_len_r[31:0]);
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <= container_val_r;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_ORDER_VAL;
                                        end else begin
                                            // Overwrite → advance (used unchanged).
                                            container_src_idx_r <= container_src_idx_r + 32'd1;
                                            container_phase_r   <= CP_BULK_INS;
                                        end
                                    end
                                end
                                CP_DICT_ORDER_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r <= pycore_dict_order_tag_addr(
                                            container_order_ptr_r, container_order_len_r[31:0]);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_ORDER_TAG;
                                    end
                                end
                                CP_DICT_ORDER_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_insert_new_r   <= 1'b0;
                                        container_used_r         <= container_used_r + 64'd1;
                                        container_order_len_r    <= container_order_len_r + 64'd1;
                                        container_dict_version_r <=
                                            container_dict_version_r + 64'd1;
                                        container_src_idx_r      <= container_src_idx_r + 32'd1;
                                        container_phase_r        <= CP_BULK_INS;
                                    end
                                end

                                // ---- Finalize: header (done above) → meta → pop.
                                CP_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <=
                                            pycore_dict_meta_addr(container_base_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= pycore_dict_meta(
                                            container_dict_version_r, container_order_len_r);
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_META_FINAL;
                                    end
                                end
                                CP_DICT_META_FINAL: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_contam_r) begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <=
                                                RF_AW'(container_dst_rf_addr_r);
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_MUT_COLLEC,
                                                pycore_mut_set_contaminated(cont_rs1_val));
                                        end
                                        tos_r             <= tos_r - RF_AW'(1);
                                        fetch_skip_r      <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end
                                end

                                CP_DONE: ;
                                default: ;
                            endcase
                        end // CONT_DICT_UPDATE

                        // =====================================================
                        // DICT_MERGE — build a fresh combined dict. A = rs1 at
                        // RF[tos-1-arg]; B = rs2 at TOS; pop B, leave result in
                        // A's slot. Empty-dest fast path aliases B into A.
                        // Non-empty uncontaminated → excore. Contaminated →
                        // pycore builds C = copy(A) then updates with B (dup key
                        // → TYPE trap).
                        // =====================================================
                        //
                        // NB: In valid CPython, DICT_MERGE only appears for call
                        // **kwargs, whose keys are always strings — so con(A) /
                        // con(B) are never set and the contaminated build-C loop
                        // below is effectively unreachable. It is implemented for
                        // completeness and mirrors the validated DICT_UPDATE
                        // insert engine (fresh target C, dup key → TYPE trap).
                        CONT_DICT_MERGE: begin
                            unique case (container_phase_r)
                                CP_INIT: begin
                                    if (!pycore_is_dict(cont_rs1_tag, cont_rs1_val) ||
                                        !pycore_is_dict(cont_rs2_tag, cont_rs2_val)) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        container_base_r         <= cont_rs1_addr;
                                        container_src_base_r     <= cont_rs2_addr;
                                        container_contam_r       <= cont_rs1_contam |
                                                                    cont_rs2_contam;
                                        container_dst_rf_addr_r  <=
                                            {2'b0, tos_r} - 9'd1 - {2'b0, cur_arg_r[6:0]};
                                        container_dmem_addr_r    <= cont_rs1_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
                                    end
                                end
                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_dict_hdr_used == 64'd0) begin
                                            // Empty dest: alias source into dest
                                            // slot; pop TOS (CALL_FUNCTION_EX
                                            // **kwargs fast path).
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(
                                                {2'b0, tos_r} - 9'd1
                                                - {2'b0, cur_arg_r[6:0]});
                                            container_wb_data_r <= rs2_r;
                                            tos_r <= tos_r - RF_AW'(1);
                                            fetch_skip_r <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else if (!cont_rs1_contam && !cont_rs2_contam &&
                                                     EXCORE_EN &&
                                                     pycore_trap_recoverable(
                                                         PY_TRAP_DICT_MERGE)) begin
                                            // Non-empty, uncontaminated: excore
                                            // builds a fresh merged dict C (dup
                                            // key → fatal TYPE) and returns it via
                                            // pop 2 / push 1, landing C where dest
                                            // A was (oparg == 1 kwargs merge).
                                            trap_marshal_pending_r     <= 1'b1;
                                            trap_marshal_code_r        <= PY_TRAP_DICT_MERGE;
                                            trap_marshal_entry_count_r <= 3'd2;
                                            trap_marshal_entries_r[0]  <= rs1_r;
                                            trap_marshal_entries_r[1]  <= rs2_r;
                                            container_phase_r          <= CP_DONE;
                                        end else begin
                                            // Contaminated non-empty merge: pycore
                                            // builds fresh C = merge(A, B).
                                            container_bulk_size_r <= cont_dict_hdr_used;
                                            container_old_slots_r <= cont_dict_hdr_slots[31:0];
                                            container_dmem_addr_r <=
                                                pycore_dict_table_ptr_addr(container_base_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_DICT_META;
                                        end
                                    end
                                end

                                // A packed ptr acked → A table; read B header.
                                CP_DICT_META: begin
                                    if (!container_dmem_pending_r) begin
                                        container_old_table_r <= cont_dict_table_ptr;
                                        container_dmem_addr_r    <= container_src_base_r;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_SRC_HDR;
                                    end
                                end
                                // B header acked → usedB / B slots; read B ptr.
                                CP_SRC_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        container_bulk_size_r <= container_bulk_size_r +
                                            pycore_dict_used_from_hdr(container_rd_data_r);
                                        container_src_slots_r <=
                                            pycore_dict_slot_count_from_hdr(container_rd_data_r);
                                        container_dmem_addr_r <=
                                            pycore_dict_table_ptr_addr(container_src_base_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_BULK_RD_KEY;
                                    end
                                end
                                // B packed ptr acked → B table; allocate C.
                                CP_BULK_RD_KEY: begin
                                    if (!container_dmem_pending_r) begin
                                        container_src_base_r <= container_rd_data_r[31:0];
                                        container_phase_r    <= CP_BULK_SRC_HDR;
                                    end
                                end
                                CP_BULK_SRC_HDR: begin
                                    begin
                                        logic [31:0] new_slots;
                                        logic [31:0] c_base;
                                        logic [31:0] c_order;
                                        logic [31:0] c_table;
                                        new_slots = pycore_dict_grow_slots(
                                            container_bulk_size_r, 32'd0);
                                        c_base  = heap_ptr_r;
                                        c_order = heap_ptr_r + 32'd48;
                                        c_table = heap_ptr_r + 32'd48 + (new_slots << 5);
                                        if ((heap_ptr_r
                                                + pycore_dict_alloc_bytes(new_slots))
                                                > PYCORE_HEAP_LIMIT) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            heap_ptr_r <= heap_ptr_r +
                                                pycore_dict_alloc_bytes(new_slots);
                                            container_base_r         <= c_base;
                                            container_order_ptr_r    <= c_order;
                                            container_buf_r          <= c_table;
                                            container_slot_count_r   <= new_slots;
                                            container_used_r         <= 64'd0;
                                            container_order_len_r    <= 64'd0;
                                            container_dict_version_r <= 64'd0;
                                            container_bulk_mode_r    <= BULK_MODE_REHASH;
                                            container_src_idx_r      <= 32'd0;
                                            // Init C header {slots, 0}.
                                            container_dmem_addr_r  <= c_base;
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <= pycore_dict_header(
                                                {32'b0, new_slots}, 64'd0);
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_LIST_WB;
                                        end
                                    end
                                end
                                CP_LIST_WB: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <=
                                            pycore_dict_meta_addr(container_base_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= 128'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_COPY_TAG_WB;
                                    end
                                end
                                CP_COPY_TAG_WB: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <=
                                            pycore_dict_table_ptr_addr(container_base_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {
                                            32'b0, container_order_ptr_r,
                                            32'b0, container_buf_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_COPY_VAL_WB;
                                    end
                                end
                                CP_COPY_VAL_WB: begin
                                    if (!container_dmem_pending_r) begin
                                        // Begin merging source A (BULK_MODE_REHASH
                                        // reuses the mode bit as "walking A").
                                        container_src_idx_r <= 32'd0;
                                        container_phase_r   <= CP_BULK_INS;
                                    end
                                end

                                // Merge dispatcher: mode REHASH = A, INSERT = B.
                                CP_BULK_INS: begin
                                    if (!container_dmem_pending_r) begin
                                        logic [31:0] stbl;
                                        logic [31:0] sbnd;
                                        stbl = (container_bulk_mode_r == BULK_MODE_REHASH) ?
                                               container_old_table_r : container_src_base_r;
                                        sbnd = (container_bulk_mode_r == BULK_MODE_REHASH) ?
                                               container_old_slots_r : container_src_slots_r;
                                        if (container_src_idx_r >= sbnd) begin
                                            if (container_bulk_mode_r == BULK_MODE_REHASH) begin
                                                // A done → merge B.
                                                container_bulk_mode_r <= BULK_MODE_INSERT;
                                                container_src_idx_r   <= 32'd0;
                                            end else begin
                                                // Both done → commit C header.
                                                container_dmem_addr_r  <= container_base_r;
                                                container_dmem_we_r    <= 1'b1;
                                                container_dmem_wdata_r <= pycore_dict_header(
                                                    {32'b0, container_slot_count_r},
                                                    container_used_r);
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r <= CP_TAG;
                                            end
                                        end else begin
                                            container_dmem_addr_r <= pycore_dict_ktag_addr(
                                                stbl, container_src_idx_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_NAME_TAG;
                                        end
                                    end
                                end
                                CP_NAME_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        logic [31:0] stbl;
                                        stbl = (container_bulk_mode_r == BULK_MODE_REHASH) ?
                                               container_old_table_r : container_src_base_r;
                                        if (pycore_dict_slot_empty(container_rd_data_r) ||
                                            pycore_dict_tombstone(
                                                container_rd_data_r[3:0])) begin
                                            container_src_idx_r <= container_src_idx_r + 32'd1;
                                            container_phase_r   <= CP_BULK_INS;
                                        end else begin
                                            container_tag_r <= container_rd_data_r[3:0];
                                            container_dmem_addr_r <= pycore_dict_kval_addr(
                                                stbl, container_src_idx_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_BULK_RD_VAL;
                                        end
                                    end
                                end
                                CP_BULK_RD_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        logic [31:0] stbl;
                                        stbl = (container_bulk_mode_r == BULK_MODE_REHASH) ?
                                               container_old_table_r : container_src_base_r;
                                        container_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <= pycore_dict_vval_addr(
                                            stbl, container_src_idx_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_DICT_RD_VVAL;
                                    end
                                end
                                CP_DICT_RD_VVAL: begin
                                    if (!container_dmem_pending_r) begin
                                        logic [31:0] stbl;
                                        stbl = (container_bulk_mode_r == BULK_MODE_REHASH) ?
                                               container_old_table_r : container_src_base_r;
                                        container_order_shift_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <= pycore_dict_vtag_addr(
                                            stbl, container_src_idx_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_DICT_RD_VTAG;
                                    end
                                end
                                CP_DICT_RD_VTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        logic [31:0] probe0;
                                        container_order_shift_tag_r <= container_rd_data_r[3:0];
                                        probe0 = pycore_dict_key_hash(
                                                     container_tag_r, container_val_r)
                                                 & (container_slot_count_r - 32'd1);
                                        container_probe_r      <= probe0;
                                        container_probe_n_r    <= 32'd0;
                                        container_tomb_valid_r <= 1'b0;
                                        container_dmem_addr_r  <= pycore_dict_ktag_addr(
                                            container_buf_r, probe0);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_DICT_PROBE;
                                    end
                                end
                                CP_DICT_PROBE: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_probe_n_r >= container_slot_count_r) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_probe_n_r <= container_probe_n_r + 32'd1;
                                            if (pycore_dict_slot_empty(
                                                    container_rd_data_r)) begin
                                                container_dmem_addr_r  <= pycore_dict_kval_addr(
                                                    container_buf_r, container_probe_r);
                                                container_dmem_we_r    <= 1'b1;
                                                container_dmem_wdata_r <= container_val_r;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r <= CP_DICT_WR_KVAL;
                                            end else begin
                                                container_probe_tag_r <= container_rd_data_r[3:0];
                                                container_dmem_addr_r <= pycore_dict_kval_addr(
                                                    container_buf_r, container_probe_r);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r <= CP_DICT_CHK_VAL;
                                            end
                                        end
                                    end
                                end
                                CP_DICT_CHK_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_dict_key_match) begin
                                            // Duplicate key across A/B → TypeError.
                                            container_type_trap_r <= 1'b1;
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
                                        container_dmem_wdata_r <= pycore_dict_key_tag_word(
                                            container_tag_r, container_val_r);
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_WR_KTAG;
                                    end
                                end
                                CP_DICT_WR_KTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_dict_vval_addr(
                                            container_buf_r, container_probe_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= container_order_shift_val_r;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_WR_VVAL;
                                    end
                                end
                                CP_DICT_WR_VVAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_dict_vtag_addr(
                                            container_buf_r, container_probe_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <=
                                            {124'b0, container_order_shift_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_WR_VTAG;
                                    end
                                end
                                CP_DICT_WR_VTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r <= pycore_dict_order_val_addr(
                                            container_order_ptr_r, container_order_len_r[31:0]);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= container_val_r;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_ORDER_VAL;
                                    end
                                end
                                CP_DICT_ORDER_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r <= pycore_dict_order_tag_addr(
                                            container_order_ptr_r, container_order_len_r[31:0]);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_ORDER_TAG;
                                    end
                                end
                                CP_DICT_ORDER_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_used_r         <= container_used_r + 64'd1;
                                        container_order_len_r    <= container_order_len_r + 64'd1;
                                        container_dict_version_r <=
                                            container_dict_version_r + 64'd1;
                                        container_src_idx_r      <= container_src_idx_r + 32'd1;
                                        container_phase_r        <= CP_BULK_INS;
                                    end
                                end

                                // Finalize: C header (done) → C meta → RF + pop.
                                CP_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <=
                                            pycore_dict_meta_addr(container_base_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= pycore_dict_meta(
                                            container_dict_version_r, container_order_len_r);
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_META_FINAL;
                                    end
                                end
                                CP_DICT_META_FINAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(container_dst_rf_addr_r);
                                        container_wb_data_r <= pycore_make_mut(
                                            PY_MUT_DICT, {32'b0, container_base_r},
                                            container_contam_r);
                                        tos_r             <= tos_r - RF_AW'(1);
                                        fetch_skip_r      <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end
                                end

                                CP_DONE: ;
                                default: ;
                            endcase
                        end // CONT_DICT_MERGE
