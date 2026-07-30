// pycore_cont_list.svh — LIST/TUPLE/iterator arms of S_CONTAINER.
// Included inside pycore_core's unique case (container_op_r). Do not compile alone.
                        CONT_BUILD_LIST: begin
                            unique case (container_phase_r)

                                // Phase 0 (CP_INIT): check OOM (object + buffer
                                // together) and issue the object's header write.
                                CP_INIT: begin
                                    // OOM check: object (32B) + buffer (count*32B,
                                    // 0 for the empty-list case).
                                    if ((heap_ptr_r + cont_bl_alloc) > PYCORE_HEAP_LIMIT) begin
                                        container_mem_fault_r <= 1'b1;
                                    end else begin
                                        // Object base (stable handle target).
                                        container_base_r       <= heap_ptr_r;
                                        // Buffer base immediately follows the 32B
                                        // object; irrelevant (never read) when
                                        // count==0, where ob_item is written 0.
                                        container_buf_r         <= heap_ptr_r + 32'd32;
                                        // Issue header write: {capacity, length}.
                                        container_dmem_addr_r  <= heap_ptr_r;
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= pycore_list_header(
                                            {57'b0, container_count_r},
                                            {57'b0, container_count_r});
                                        container_dmem_pending_r <= 1'b1;
                                        // Advance heap_ptr by the full allocation
                                        // now — capacity == count exactly (no
                                        // over-allocation), matching CPython
                                        // list-literal semantics.
                                        heap_ptr_r             <= heap_ptr_r + cont_bl_alloc;
                                        // Pre-load RF address for element 0.
                                        container_rf_addr_r <= RF_AW'(
                                            {2'b0, tos_r} - {2'b0, container_count_r});
                                        container_idx_r        <= 7'd0;
                                        container_phase_r      <= CP_HDR;
                                    end
                                end

                                // Phase 1 (CP_HDR): wait for header-write ack,
                                // then write ob_item (buffer address, or 0 for
                                // an empty list — no buffer allocation).
                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_list_obitem_addr(
                                            container_base_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {64'b0,
                                            (container_count_r == 7'd0) ? 32'd0 : container_buf_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r      <= CP_LIST_BUF;
                                    end
                                end

                                // Phase 2 (CP_LIST_BUF): wait for ob_item-write
                                // ack.  Empty list: commit handle now.  Non-empty
                                // (also reached by looping back from CP_TAG for
                                // element i>0): RF address settled; issue the
                                // element value write against the buffer base.
                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_count_r == 7'd0) begin
                                            // Empty list: object only, ob_item=0.
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'({2'b0, tos_r});
                                            container_wb_data_r <= pycore_make_mut(
                                                PY_MUT_LIST,
                                                {32'b0, container_base_r});
                                            tos_r             <= tos_r + RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            // Save element from RF (async read valid now).
                                            container_tag_r        <= cont_rf_rs1_tag;
                                            container_val_r        <= cont_rf_rs1_val;
                                            // Issue element value write into the buffer.
                                            container_dmem_addr_r  <= pycore_list_val_addr(
                                                container_buf_r,
                                                {25'b0, container_idx_r});
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <= cont_rf_rs1_val;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r      <= CP_VAL;
                                        end
                                    end
                                end

                                // Phase 3 (CP_VAL): wait for element value-write ack.
                                CP_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        // Issue element tag write.
                                        container_dmem_addr_r  <= pycore_list_tag_addr(
                                            container_buf_r,
                                            {25'b0, container_idx_r});
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r      <= CP_TAG;
                                    end
                                end

                                // Phase 4 (CP_TAG): wait for element tag-write ack.
                                // When all elements are written, commit the list
                                // handle here (in the same ack cycle) and advance
                                // to CP_DONE, which is an intentionally empty
                                // terminal phase that triggers S_FETCH transition.
                                CP_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_idx_r + 7'd1 < container_count_r) begin
                                            // More elements: advance to next, and
                                            // loop back to CP_LIST_BUF (no dmem op
                                            // is pending, so the guard there passes
                                            // immediately and issues the next
                                            // element's value write).
                                            container_idx_r     <= container_idx_r + 7'd1;
                                            container_rf_addr_r <= RF_AW'(
                                                {2'b0, tos_r}
                                                - {2'b0, container_count_r}
                                                + {2'b0, container_idx_r}
                                                + 9'd1);
                                            container_phase_r   <= CP_LIST_BUF;
                                        end else begin
                                            // All elements written — commit list.
                                            // Push the list handle to RF[tos-count].
                                            // heap_ptr already advanced by exactly
                                            // cont_bl_alloc back in CP_INIT.
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(
                                                {2'b0, tos_r} - {2'b0, container_count_r});
                                            container_wb_data_r <= pycore_make_mut(
                                                PY_MUT_LIST,
                                                {32'b0, container_base_r});
                                            tos_r            <= tos_r
                                                - {2'b0, container_count_r} + 7'd1;
                                            fetch_skip_r     <= 1'b1;
                                            // Advance to terminal phase; always_comb
                                            // transitions to S_FETCH when phase=CP_DONE.
                                            container_phase_r   <= CP_DONE;
                                        end
                                    end
                                end

                                // Phase 5 (CP_DONE): terminal marker — do nothing.
                                // All commit work was done in CP_TAG / empty
                                // CP_LIST_BUF.  The always_comb state-next logic
                                // transitions to S_FETCH the same cycle
                                // container_phase_r=CP_DONE.
                                CP_DONE: ;

                                default: ;

                            endcase
                        end // CONT_BUILD_LIST

                        CONT_SUBSCR_LIST: begin
                            // rs1_r = container (MUT_COLLEC/PY_MUT_LIST expected)
                            // rs2_r = key       (INT or BOOL expected)
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    // Type checks.
                                    if (!pycore_is_list(cont_rs1_tag, cont_rs1_val)) begin
                                        container_type_trap_r <= 1'b1;
                                    end else if (cont_rs2_tag != PY_TAG_INT &&
                                                 cont_rs2_tag != PY_TAG_BOOL) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        // Issue header read (object address).
                                        container_base_r         <= cont_rs1_addr;
                                        container_dmem_addr_r    <= cont_rs1_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        // container_rd_data_r = header {capacity, length}.
                                        // Bounds check: 0 <= key < length.
                                        if (cont_key_u >= cont_hdr_len) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            // Read ob_item (buffer address).
                                            container_dmem_addr_r <= pycore_list_obitem_addr(
                                                container_base_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_LIST_BUF;
                                        end
                                    end
                                end

                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        // container_rd_data_r = {0, ob_item}.
                                        container_buf_r <= cont_obitem_buf;
                                        // Read element value from the buffer.
                                        container_dmem_addr_r <= pycore_list_val_addr(
                                            cont_obitem_buf,
                                            cont_key_u[31:0]);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_VAL;
                                    end
                                end

                                CP_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        // Save value, read tag.
                                        container_val_r       <= container_rd_data_r;
                                        // Compute tag address: val_addr + 16.
                                        container_dmem_addr_r <= container_dmem_addr_r + 32'd16;
                                        container_dmem_we_r   <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r     <= CP_TAG;
                                    end
                                end

                                CP_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        // Assemble result and write back to RF.
                                        // Tag is in container_rd_data_r[3:0].
                                        // Result lands at tos-2 (container slot).
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                        container_wb_data_r <= pycore_make_entry(
                                            container_rd_data_r[3:0],
                                            container_val_r);
                                        // Pop 1 (key): tos-2 keeps the result.
                                        tos_r             <= tos_r - RF_AW'(1);
                                        fetch_skip_r      <= 1'b1;
                                        // Advance to terminal marker to prevent
                                        // this branch from executing a second time
                                        // while the FSM lingers in S_CONTAINER.
                                        container_phase_r <= CP_DONE;
                                    end
                                end

                                // CP_DONE: terminal — nothing to execute.
                                // State transitions to S_FETCH via always_comb.
                                CP_DONE: ;

                                default: ;

                            endcase
                        end // CONT_SUBSCR_LIST

                        CONT_GET_ITER: begin
                            unique case (container_phase_r)
                                CP_INIT: begin
                                    if (pycore_is_list(cont_rs1_tag, cont_rs1_val)) begin
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(1));
                                        container_wb_data_r <= pycore_make_entry(
                                            PY_TAG_ITER,
                                            pycore_iter_value(
                                                PY_ITER_KIND_LIST,
                                                32'd0, 32'd0, cont_rs1_addr));
                                        container_phase_r <= CP_ITER_WB;
                                    end else if (cont_rs1_tag == PY_TAG_TUPLE) begin
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(1));
                                        container_wb_data_r <= pycore_make_entry(
                                            PY_TAG_ITER,
                                            pycore_iter_value(
                                                PY_ITER_KIND_TUPLE, 32'd0,
                                                cont_tuple_size[31:0],
                                                cont_rs1_addr));
                                        container_phase_r <= CP_ITER_WB;
                                    end else begin
                                        container_type_trap_r <= 1'b1;
                                    end
                                end

                                CP_ITER_WB: begin
                                    fetch_skip_r     <= 1'b1;
                                    container_phase_r <= CP_DONE;
                                end

                                CP_DONE: ;
                                default: ;
                            endcase
                        end // CONT_GET_ITER

                        CONT_FOR_ITER: begin
                            unique case (container_phase_r)
                                CP_INIT: begin
                                    if (cont_rs1_tag != PY_TAG_ITER ||
                                        !cont_iter_valid) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        unique case (cont_iter_kind)
                                            PY_ITER_KIND_TUPLE: begin
                                                if (cont_iter_index >= cont_iter_size) begin
                                                    redirect_pending_r <= 1'b1;
                                                    redirect_tgt_r <= cur_pc_r + 32'd1 +
                                                        {24'b0, PY_CACHE_FOR_ITER} +
                                                        cur_arg_r + 32'd1;
                                                    fetch_skip_r      <= 1'b1;
                                                    container_phase_r <= CP_DONE;
                                                end else begin
                                                    container_dmem_addr_r <=
                                                        pycore_tuple_val_addr(
                                                            cont_iter_addr,
                                                            cont_iter_index);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                    container_phase_r        <= CP_VAL;
                                                end
                                            end
                                            PY_ITER_KIND_LIST: begin
                                                // LIST: read the current header first.
                                                container_dmem_addr_r    <= cont_iter_addr;
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r        <= CP_HDR;
                                            end
                                            default: begin
                                                container_type_trap_r <= 1'b1;
                                            end
                                        endcase
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        if ({32'b0, cont_iter_index} >= cont_hdr_len) begin
                                            redirect_pending_r <= 1'b1;
                                            redirect_tgt_r <= cur_pc_r + 32'd1 +
                                                {24'b0, PY_CACHE_FOR_ITER} +
                                                cur_arg_r + 32'd1;
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            container_dmem_addr_r <=
                                                pycore_list_obitem_addr(cont_iter_addr);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_LIST_BUF;
                                        end
                                    end
                                end

                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r <= pycore_list_val_addr(
                                            cont_obitem_buf, cont_iter_index);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_VAL;
                                    end
                                end

                                CP_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_val_r       <= container_rd_data_r;
                                        container_dmem_addr_r <= container_dmem_addr_r + 32'd16;
                                        container_dmem_we_r   <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r     <= CP_TAG;
                                    end
                                end

                                CP_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_tag_r     <= container_rd_data_r[3:0];
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(1));
                                        container_wb_data_r <= pycore_make_entry(
                                            PY_TAG_ITER,
                                            pycore_iter_value(
                                                cont_iter_kind,
                                                cont_iter_index + 32'd1,
                                                cont_iter_size,
                                                cont_iter_addr));
                                        container_phase_r <= CP_ITER_WB;
                                    end
                                end

                                CP_ITER_WB: begin
                                    container_wb_we_r   <= 1'b1;
                                    container_wb_addr_r <= RF_AW'(tos_r);
                                    container_wb_data_r <= pycore_make_entry(
                                        container_tag_r, container_val_r);
                                    container_phase_r <= CP_ITEM_WB;
                                end

                                CP_ITEM_WB: begin
                                    tos_r             <= tos_r + RF_AW'(1);
                                    fetch_skip_r      <= 1'b1;
                                    container_phase_r <= CP_DONE;
                                end

                                CP_DONE: ;
                                default: ;
                            endcase
                        end // CONT_FOR_ITER

                        CONT_STORE_LIST: begin
                            // rs1_r = key       (INT or BOOL)
                            // rs2_r = container (MUT_COLLEC/PY_MUT_LIST)
                            // value at RF[tos-3] (read via container_rf_addr_r)
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    // Type checks.
                                    if (!pycore_is_list(cont_rs2_tag, cont_rs2_val)) begin
                                        container_type_trap_r <= 1'b1;
                                    end else if (cont_rs1_tag != PY_TAG_INT &&
                                                 cont_rs1_tag != PY_TAG_BOOL) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        // Set RF address to read value (tos-3).
                                        container_rf_addr_r      <= RF_AW'(tos_r - RF_AW'(3));
                                        // Start header read (object address).
                                        container_base_r         <= cont_rs2_addr;
                                        container_dmem_addr_r    <= cont_rs2_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        // RF[tos-3] value now valid (addr set last cycle).
                                        // Bounds check using cont_key_u_st (key is rs1).
                                        if (cont_key_u_st >= cont_hdr_len) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            // Read ob_item (buffer address).
                                            container_dmem_addr_r <= pycore_list_obitem_addr(
                                                container_base_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_LIST_BUF;
                                        end
                                    end
                                end

                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        // container_rd_data_r = {0, ob_item}.
                                        // Save value from RF (addr settled since
                                        // CP_INIT; unaffected by the intervening
                                        // header/ob_item reads).
                                        container_buf_r         <= cont_obitem_buf;
                                        container_tag_r        <= cont_rf_rs1_tag;
                                        container_val_r        <= cont_rf_rs1_val;
                                        // Write value slot into the buffer.
                                        container_dmem_addr_r  <= pycore_list_val_addr(
                                            cont_obitem_buf,
                                            cont_key_u_st[31:0]);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= cont_rf_rs1_val;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r      <= CP_VAL;
                                    end
                                end

                                CP_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        // Write tag slot.
                                        container_dmem_addr_r  <= container_dmem_addr_r + 32'd16;
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r      <= CP_TAG;
                                    end
                                end

                                CP_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        // Pop 3 (key, container, value).
                                        tos_r             <= tos_r - RF_AW'(3);
                                        fetch_skip_r      <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end
                                end

                                // CP_DONE: terminal — nothing to execute.
                                CP_DONE: ;

                                default: ;

                            endcase
                        end // CONT_STORE_LIST

                        CONT_DELETE_LIST: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (!pycore_is_list(cont_rs2_tag, cont_rs2_val)) begin
                                        container_type_trap_r <= 1'b1;
                                    end else if (cont_rs1_tag != PY_TAG_INT &&
                                                 cont_rs1_tag != PY_TAG_BOOL) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        container_base_r         <= cont_rs2_addr;
                                        container_dmem_addr_r    <= cont_rs2_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        container_list_hdr_r <= container_rd_data_r;
                                        // Delete index from key (rs1).
                                        if (cont_key_u_st >= cont_hdr_len) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            // Last element: length-- only (no
                                            // shift). Mid delete: trap before
                                            // any commit (no ob_item needed).
                                            if (cont_key_u_st + 64'd1
                                                    == cont_hdr_len) begin
                                                container_dmem_addr_r  <=
                                                    container_base_r;
                                                container_dmem_we_r     <= 1'b1;
                                                container_dmem_wdata_r  <=
                                                    pycore_list_header(
                                                        cont_hdr_cap,
                                                        cont_hdr_len - 64'd1);
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r       <=
                                                    CP_LIST_WB;
                                            end else if (EXCORE_EN &&
                                                pycore_trap_recoverable(
                                                    PY_TRAP_LIST_DELETE)) begin
                                                trap_marshal_pending_r     <= 1'b1;
                                                trap_marshal_code_r        <=
                                                    PY_TRAP_LIST_DELETE;
                                                trap_marshal_entry_count_r <= 3'd2;
                                                trap_marshal_entries_r[0]  <= rs2_r;
                                                trap_marshal_entries_r[1]  <= rs1_r;
                                                container_phase_r          <=
                                                    CP_DONE;
                                            end else begin
                                                container_list_delete_trap_r <=
                                                    1'b1;
                                            end
                                        end
                                    end
                                end

                                CP_LIST_WB: begin
                                    if (!container_dmem_pending_r) begin
                                        tos_r             <= tos_r - RF_AW'(2);
                                        fetch_skip_r      <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_DELETE_LIST

                        CONT_LIST_APPEND: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (!pycore_is_list(cont_rs1_tag, cont_rs1_val)) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        container_base_r         <= cont_rs1_addr;
                                        container_dmem_addr_r    <= cont_rs1_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_hdr_len < cont_hdr_cap) begin
                                            // Fast path: spare capacity exists.
                                            // Snapshot the header now — it will
                                            // be needed again at CP_TAG, after
                                            // container_rd_data_r has been
                                            // overwritten by the ob_item read.
                                            container_list_hdr_r  <= container_rd_data_r;
                                            container_dmem_addr_r <= pycore_list_obitem_addr(
                                                container_base_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_LIST_BUF;
                                        end else if (EXCORE_EN &&
                                                     pycore_trap_recoverable(PY_TRAP_LIST_GROW)) begin
                                            // Full, but the excore can service
                                            // this: marshal the operands it
                                            // needs (list handle + element —
                                            // exactly rs1_r/rs2_r, already
                                            // decoded for this op) and hand off
                                            // instead of halting.  No RF, heap,
                                            // or dmem-write commit has happened.
                                            trap_marshal_pending_r    <= 1'b1;
                                            trap_marshal_code_r       <= PY_TRAP_LIST_GROW;
                                            trap_marshal_entry_count_r <= 3'd2;
                                            trap_marshal_entries_r[0] <= rs1_r; // list handle
                                            trap_marshal_entries_r[1] <= rs2_r; // element
                                            container_phase_r         <= CP_DONE;
                                        end else begin
                                            // Full, no excore: raise the fatal
                                            // grow trap (Phase A/B behavior).
                                            // No RF, heap, or dmem-write commit
                                            // has happened.
                                            container_list_grow_trap_r <= 1'b1;
                                        end
                                    end
                                end

                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        // container_rd_data_r = {0, ob_item}.
                                        container_buf_r        <= cont_obitem_buf;
                                        container_tag_r         <= cont_rs2_tag;
                                        container_dmem_addr_r   <= pycore_list_val_addr(
                                            cont_obitem_buf,
                                            cont_list_append_idx);
                                        container_dmem_we_r     <= 1'b1;
                                        container_dmem_wdata_r  <= cont_rs2_val;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r       <= CP_VAL;
                                    end
                                end

                                CP_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_list_tag_addr(
                                            container_buf_r,
                                            cont_list_append_idx);
                                        container_dmem_we_r     <= 1'b1;
                                        container_dmem_wdata_r  <= {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r       <= CP_TAG;
                                    end
                                end

                                CP_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= container_base_r;
                                        container_dmem_we_r     <= 1'b1;
                                        container_dmem_wdata_r  <= pycore_list_header(
                                            pycore_list_capacity(container_list_hdr_r),
                                            pycore_list_length(container_list_hdr_r) + 64'd1);
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r       <= CP_LIST_WB;
                                    end
                                end

                                CP_LIST_WB: begin
                                    if (!container_dmem_pending_r) begin
                                        // Pop 1 (the appended element); the list
                                        // handle beneath it is left in place.
                                        tos_r             <= tos_r - RF_AW'(1);
                                        fetch_skip_r      <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end
                                end

                                // CP_DONE: terminal — nothing to execute.
                                CP_DONE: ;

                                default: ;

                            endcase
                        end // CONT_LIST_APPEND

                        CONT_LIST_EXTEND: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (!pycore_is_list(cont_rs1_tag, cont_rs1_val)) begin
                                        container_type_trap_r <= 1'b1;
                                    end else if (!pycore_is_list(cont_rs2_tag, cont_rs2_val) &&
                                                 cont_rs2_tag != PY_TAG_TUPLE) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        container_base_r         <= cont_rs1_addr;
                                        container_dmem_addr_r    <= cont_rs1_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        // Snapshot dst header (unused for the
                                        // trap path; kept for empty/self checks).
                                        container_list_hdr_r <= container_rd_data_r;
                                        if (cont_rs2_tag == PY_TAG_TUPLE) begin
                                            container_src_len_r <=
                                                cont_tuple_size_rs2[31:0];
                                            container_phase_r <= CP_SRC_HDR;
                                        end else if (cont_rs2_addr == cont_rs1_addr) begin
                                            // Self-extend: src_len = dst len.
                                            container_src_len_r <= cont_hdr_len[31:0];
                                            container_phase_r   <= CP_SRC_HDR;
                                        end else begin
                                            // Distinct list source: read header.
                                            container_dmem_addr_r    <= cont_rs2_addr;
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_SRC_HDR;
                                        end
                                    end
                                end

                                CP_SRC_HDR: begin
                                    // Wait for distinct-list src header if needed.
                                    if (pycore_is_list(cont_rs2_tag, cont_rs2_val) &&
                                        cont_rs2_addr != cont_rs1_addr &&
                                        container_dmem_pending_r) begin
                                        // Still waiting on src header.
                                    end else begin
                                        if (pycore_is_list(cont_rs2_tag, cont_rs2_val) &&
                                            cont_rs2_addr != cont_rs1_addr &&
                                            !container_dmem_pending_r) begin
                                            container_src_len_r <= cont_hdr_len[31:0];
                                        end
                                        // Empty source → no-op pop. Non-empty
                                        // → always LIST_EXTEND (before commit).
                                        if ((pycore_is_list(cont_rs2_tag, cont_rs2_val) &&
                                             cont_rs2_addr != cont_rs1_addr)
                                            ? (cont_hdr_len == 64'd0)
                                            : (container_src_len_r == 32'd0)) begin
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else if (EXCORE_EN &&
                                            pycore_trap_recoverable(
                                                PY_TRAP_LIST_EXTEND)) begin
                                            trap_marshal_pending_r     <= 1'b1;
                                            trap_marshal_code_r        <=
                                                PY_TRAP_LIST_EXTEND;
                                            trap_marshal_entry_count_r <= 3'd2;
                                            trap_marshal_entries_r[0]  <= rs1_r;
                                            trap_marshal_entries_r[1]  <= rs2_r;
                                            container_phase_r          <= CP_DONE;
                                        end else begin
                                            container_list_extend_trap_r <= 1'b1;
                                        end
                                    end
                                end

                                CP_DONE: ;

                                default: ;

                            endcase
                        end // CONT_LIST_EXTEND

                        CONT_BUILD_TUPLE: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if ((heap_ptr_r + cont_bt_alloc) > PYCORE_HEAP_LIMIT) begin
                                        container_mem_fault_r <= 1'b1;
                                    end else if (container_count_r == 7'd0) begin
                                        // Empty tuple: no dmem writes; commit handle.
                                        container_base_r       <= heap_ptr_r;
                                        container_wb_we_r      <= 1'b1;
                                        container_wb_addr_r    <= RF_AW'({2'b0, tos_r});
                                        container_wb_data_r    <= pycore_make_entry(
                                            PY_TAG_TUPLE,
                                            {64'd0, {32'b0, heap_ptr_r}});
                                        tos_r             <= tos_r + RF_AW'(1);
                                        fetch_skip_r      <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end else begin
                                        container_base_r  <= heap_ptr_r;
                                        container_rf_addr_r <= RF_AW'(
                                            {2'b0, tos_r} - {2'b0, container_count_r});
                                        container_idx_r   <= 7'd0;
                                        container_phase_r <= CP_HDR;
                                    end
                                end

                                // RF addr settled; write element value.
                                CP_HDR: begin
                                    container_tag_r        <= cont_rf_rs1_tag;
                                    container_val_r        <= cont_rf_rs1_val;
                                    container_dmem_addr_r  <= pycore_tuple_val_addr(
                                        container_base_r, {25'b0, container_idx_r});
                                    container_dmem_we_r    <= 1'b1;
                                    container_dmem_wdata_r <= cont_rf_rs1_val;
                                    container_dmem_pending_r <= 1'b1;
                                    heap_ptr_r             <= heap_ptr_r + 32'd16;
                                    container_phase_r      <= CP_VAL;
                                end

                                CP_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_tuple_tag_addr(
                                            container_base_r, {25'b0, container_idx_r});
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        heap_ptr_r             <= heap_ptr_r + 32'd16;
                                        container_phase_r      <= CP_TAG;
                                    end
                                end

                                CP_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_idx_r + 7'd1 < container_count_r) begin
                                            container_idx_r     <= container_idx_r + 7'd1;
                                            container_rf_addr_r <= RF_AW'(
                                                {2'b0, tos_r}
                                                - {2'b0, container_count_r}
                                                + {2'b0, container_idx_r}
                                                + 9'd1);
                                            container_phase_r   <= CP_HDR;
                                        end else begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(
                                                {2'b0, tos_r} - {2'b0, container_count_r});
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_TUPLE,
                                                {{57'b0, container_count_r},
                                                 {32'b0, container_base_r}});
                                            tos_r            <= tos_r
                                                - {2'b0, container_count_r} + 7'd1;
                                            fetch_skip_r     <= 1'b1;
                                            container_phase_r   <= CP_DONE;
                                        end
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_BUILD_TUPLE

                        CONT_SUBSCR_TUPLE: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (cont_rs1_tag != PY_TAG_TUPLE) begin
                                        container_type_trap_r <= 1'b1;
                                    end else if (cont_rs2_tag != PY_TAG_INT &&
                                                 cont_rs2_tag != PY_TAG_BOOL) begin
                                        container_type_trap_r <= 1'b1;
                                    end else if (cont_key_u >= cont_tuple_size) begin
                                        container_mem_fault_r <= 1'b1;
                                    end else begin
                                        container_base_r <= cont_rs1_addr;
                                        container_dmem_addr_r <= pycore_tuple_val_addr(
                                            cont_rs1_addr, cont_key_u[31:0]);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_VAL;
                                    end
                                end

                                CP_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_val_r       <= container_rd_data_r;
                                        container_dmem_addr_r <= container_dmem_addr_r + 32'd16;
                                        container_dmem_we_r   <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r     <= CP_TAG;
                                    end
                                end

                                CP_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                        container_wb_data_r <= pycore_make_entry(
                                            container_rd_data_r[3:0],
                                            container_val_r);
                                        tos_r             <= tos_r - RF_AW'(1);
                                        fetch_skip_r      <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_SUBSCR_TUPLE

                        CONT_CONTAINS_LIST: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (!pycore_is_list(cont_rs2_tag, cont_rs2_val)) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        container_base_r         <= cont_rs2_addr;
                                        container_dmem_addr_r    <= cont_rs2_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        container_list_hdr_r <= container_rd_data_r;
                                        if (cont_hdr_len == 64'd0) begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                 cur_arg_r[0]}); // empty: in→0, not in→1
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            container_dmem_addr_r <=
                                                pycore_list_obitem_addr(container_base_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_LIST_BUF;
                                        end
                                    end
                                end

                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        container_buf_r <= cont_obitem_buf;
                                        container_idx_r <= 7'd0;
                                        container_dmem_addr_r <= pycore_list_val_addr(
                                            cont_obitem_buf, 32'd0);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_VAL;
                                    end
                                end

                                CP_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <=
                                            container_dmem_addr_r + 32'd16;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_TAG;
                                    end
                                end

                                CP_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_contains_eq) begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                 ~cur_arg_r[0]}); // found: in→1, not in→0
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else if ({25'b0, container_idx_r} + 32'd1
                                                     < cont_ext_hdr_len[31:0]) begin
                                            container_idx_r <= container_idx_r + 7'd1;
                                            container_dmem_addr_r <= pycore_list_val_addr(
                                                container_buf_r,
                                                {25'b0, container_idx_r} + 32'd1);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_VAL;
                                        end else begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                 cur_arg_r[0]}); // miss: in→0, not in→1
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_CONTAINS_LIST

                        CONT_CONTAINS_TUPLE: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (cont_rs2_tag != PY_TAG_TUPLE) begin
                                        container_type_trap_r <= 1'b1;
                                    end else if (cont_tuple_size_rs2 == 64'd0) begin
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                        container_wb_data_r <= pycore_make_entry(
                                            PY_TAG_BOOL,
                                            {{(PYCORE_VAL_WIDTH-1){1'b0}}, cur_arg_r[0]});
                                        tos_r             <= tos_r - RF_AW'(1);
                                        fetch_skip_r      <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end else begin
                                        container_src_buf_r <= cont_tuple_addr_rs2;
                                        container_src_len_r <= cont_tuple_size_rs2[31:0];
                                        container_idx_r     <= 7'd0;
                                        container_dmem_addr_r <= pycore_tuple_val_addr(
                                            cont_tuple_addr_rs2, 32'd0);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_VAL;
                                    end
                                end

                                CP_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <=
                                            container_dmem_addr_r + 32'd16;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_TAG;
                                    end
                                end

                                CP_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_contains_eq) begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                 ~cur_arg_r[0]});
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else if ({25'b0, container_idx_r} + 32'd1
                                                     < container_src_len_r) begin
                                            container_idx_r <= container_idx_r + 7'd1;
                                            container_dmem_addr_r <= pycore_tuple_val_addr(
                                                container_src_buf_r,
                                                {25'b0, container_idx_r} + 32'd1);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_VAL;
                                        end else begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                 cur_arg_r[0]});
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_CONTAINS_TUPLE

                        // UNPACK_SEQUENCE: pop LIST/TUPLE at TOS; push
                        // container_count_r elements right-to-left so
                        // seq[0] lands at TOS. Length mismatch → TYPE.
                        CONT_UNPACK_SEQ: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (cont_rs1_tag == PY_TAG_TUPLE) begin
                                        if (cont_tuple_size !=
                                                {57'b0, container_count_r}) begin
                                            container_type_trap_r <= 1'b1;
                                        end else if (container_count_r == 7'd0) begin
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            container_base_r  <= cont_rs1_addr;
                                            container_tag_r   <= PY_TAG_TUPLE;
                                            container_idx_r   <= container_count_r - 7'd1;
                                            tos_r             <= tos_r - RF_AW'(1);
                                            container_dmem_addr_r <=
                                                pycore_tuple_val_addr(
                                                    cont_rs1_addr,
                                                    {25'b0, container_count_r - 7'd1});
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_VAL;
                                        end
                                    end else if (pycore_is_list(cont_rs1_tag, cont_rs1_val)) begin
                                        container_base_r         <= cont_rs1_addr;
                                        container_tag_r          <= PY_TAG_MUT_COLLEC;
                                        container_dmem_addr_r    <= cont_rs1_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
                                    end else begin
                                        container_type_trap_r <= 1'b1;
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_hdr_len !=
                                                {57'b0, container_count_r}) begin
                                            container_type_trap_r <= 1'b1;
                                        end else if (container_count_r == 7'd0) begin
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            container_dmem_addr_r <=
                                                pycore_list_obitem_addr(
                                                    container_base_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_LIST_BUF;
                                        end
                                    end
                                end

                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        container_buf_r   <= cont_obitem_buf;
                                        container_idx_r   <= container_count_r - 7'd1;
                                        tos_r             <= tos_r - RF_AW'(1);
                                        container_dmem_addr_r <=
                                            pycore_list_val_addr(
                                                cont_obitem_buf,
                                                {25'b0, container_count_r - 7'd1});
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_VAL;
                                    end
                                end

                                CP_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_val_r       <= container_rd_data_r;
                                        container_dmem_addr_r <=
                                            container_dmem_addr_r + 32'd16;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_TAG;
                                    end
                                end

                                CP_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(tos_r);
                                        container_wb_data_r <= pycore_make_entry(
                                            container_rd_data_r[3:0],
                                            container_val_r);
                                        tos_r <= tos_r + RF_AW'(1);
                                        if (container_idx_r == 7'd0) begin
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            container_idx_r <= container_idx_r - 7'd1;
                                            if (container_tag_r == PY_TAG_TUPLE) begin
                                                container_dmem_addr_r <=
                                                    pycore_tuple_val_addr(
                                                        container_base_r,
                                                        {25'b0,
                                                         container_idx_r - 7'd1});
                                            end else begin
                                                container_dmem_addr_r <=
                                                    pycore_list_val_addr(
                                                        container_buf_r,
                                                        {25'b0,
                                                         container_idx_r - 7'd1});
                                            end
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_VAL;
                                        end
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_UNPACK_SEQ

