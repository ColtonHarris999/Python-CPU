// CONT_RAISE — RAISE_VARARGS 0/1 (§7.5): reuse active_exc_r for bare raise,
// or build/reuse TOS OBK_EXCEPTION, then walk co_exceptiontable (code field 7).
// Bare raise without an active exception is fatal PY_TRAP_RAISE until a boot
// RuntimeError sidecar exists; never probe builtins combinationally in EX.
//
// Phases reuse CP_* codes (op-local).
//   container_probe_r      : exception-object write step, then table byte index
//   container_slot_count_r : exception-table tuple size (bytes)
//   container_buf_r        : table tuple element base address
//   container_order_len_r  : varint accumulator
//   container_order_idx_r  : entry field (0=start,1=length,2=target,3=depth_lasti)
//   container_range_*_r    : start_rel / end_rel / target_rel (slot units)
//   container_used_r       : depth_lasti
//   container_val_r/tag_r  : raising type, then OBK_EXCEPTION handle value
CONT_RAISE: begin
    unique case (container_phase_r)
        CP_INIT: begin
            if (cur_arg_r == 32'd0) begin
                if (!active_exc_valid_r ||
                    (pycore_get_tag(active_exc_r) != PY_TAG_OBJECT)) begin
                    container_raise_trap_r <= 1'b1;
                    fetch_skip_r           <= 1'b1;
                    container_phase_r      <= CP_DONE;
                end else begin
                    // The handler-established active exception is already an
                    // OBK_EXCEPTION. Keep stack effect 0, recover its type,
                    // then enter the same CP_VAL table walk as `raise e`.
                    container_tag_r  <= PY_TAG_OBJECT;
                    container_val_r  <= pycore_get_val(active_exc_r);
                    container_base_r <= pycore_get_val(active_exc_r)[31:0];
                    container_dmem_addr_r <= pycore_obj_field_val_addr(
                        pycore_get_val(active_exc_r)[31:0], 32'd0);
                    container_dmem_we_r      <= 1'b0;
                    container_dmem_pending_r <= 1'b1;
                    container_probe_r        <= 32'd7;
                    container_phase_r        <= CP_HDR;
                end
            end else begin
                container_tag_r <= pycore_get_tag(rs1_r);
                container_val_r <= pycore_get_val(rs1_r);
                raise_type_entry_r <= rs1_r;
                if (pycore_get_tag(rs1_r) != PY_TAG_OBJECT) begin
                    container_type_trap_r <= 1'b1;
                end else begin
                    // One head read distinguishes a type from an existing
                    // exception instance. Allocation follows only for TYPE.
                    container_dmem_addr_r    <= cont_rs1_addr;
                    container_dmem_we_r      <= 1'b0;
                    container_dmem_pending_r <= 1'b1;
                    container_probe_r        <= 32'd6;
                    container_phase_r        <= CP_HDR;
                end
            end
        end

        CP_HDR: begin
            if (!container_dmem_pending_r) begin
                unique case (container_probe_r[3:0])
                    4'd6: begin
                        if (pycore_ob_kind(container_rd_data_r) ==
                                PY_OBK_EXCEPTION) begin
                            // Reuse the existing object.  Read field0 once so
                            // protocol FOR_ITER compares the canonical type
                            // even for `raise e`, where rs1 was the instance.
                            container_base_r <= container_val_r[31:0];
                            tos_r            <= tos_r - RF_AW'(1);
                            container_tag_r  <= PY_TAG_OBJECT;
                            container_dmem_addr_r <= pycore_obj_field_val_addr(
                                container_val_r[31:0], 32'd0);
                            container_dmem_we_r      <= 1'b0;
                            container_dmem_pending_r <= 1'b1;
                            container_probe_r        <= 32'd7;
                        end else if (pycore_ob_kind(container_rd_data_r) ==
                                     PY_OBK_TYPE) begin
                            if ((heap_ptr_r + PYCORE_OBJ_EXCEPTION_BYTES) >
                                    PYCORE_HEAP_LIMIT) begin
                                container_mem_fault_r <= 1'b1;
                            end else begin
                                container_base_r      <= heap_ptr_r;
                                heap_ptr_r <= heap_ptr_r +
                                    PYCORE_OBJ_EXCEPTION_BYTES;
                                container_dmem_addr_r  <= heap_ptr_r;
                                container_dmem_we_r    <= 1'b1;
                                container_dmem_wdata_r <= pycore_pack_ob_head(
                                    PY_OBK_EXCEPTION, 32'd0, 64'd0);
                                container_dmem_pending_r <= 1'b1;
                                container_probe_r <= 32'd0;
                            end
                        end else begin
                            container_type_trap_r <= 1'b1;
                        end
                    end
                    4'd7: begin
                        raise_type_entry_r <= pycore_make_entry(
                            PY_TAG_OBJECT, container_rd_data_r);
                        container_dmem_addr_r <= pycore_code_field_val_addr(
                            cur_code_r, PYCORE_CODE_FIELD_CO_EXCEPTIONTABLE);
                        container_dmem_we_r      <= 1'b0;
                        container_dmem_pending_r <= 1'b1;
                        container_phase_r        <= CP_VAL;
                    end
                    4'd0: begin
                        container_dmem_addr_r    <= container_base_r + 32'd16;
                        container_dmem_we_r      <= 1'b1;
                        container_dmem_wdata_r   <= {124'b0, PY_TAG_OBJECT};
                        container_dmem_pending_r <= 1'b1;
                        container_probe_r        <= 32'd1;
                    end
                    4'd1: begin
                        container_dmem_addr_r    <=
                            pycore_obj_field_val_addr(container_base_r, 32'd0);
                        container_dmem_we_r      <= 1'b1;
                        container_dmem_wdata_r   <= container_val_r;
                        container_dmem_pending_r <= 1'b1;
                        container_probe_r        <= 32'd2;
                    end
                    4'd2: begin
                        container_dmem_addr_r    <=
                            pycore_obj_field_tag_addr(container_base_r, 32'd0);
                        container_dmem_we_r      <= 1'b1;
                        container_dmem_wdata_r   <= {124'b0, container_tag_r};
                        container_dmem_pending_r <= 1'b1;
                        container_probe_r        <= 32'd3;
                    end
                    4'd3: begin
                        // Empty args tuple {size=0, addr=0}.
                        container_dmem_addr_r    <=
                            pycore_obj_field_val_addr(container_base_r, 32'd1);
                        container_dmem_we_r      <= 1'b1;
                        container_dmem_wdata_r   <= 128'd0;
                        container_dmem_pending_r <= 1'b1;
                        container_probe_r        <= 32'd4;
                    end
                    4'd4: begin
                        container_dmem_addr_r    <=
                            pycore_obj_field_tag_addr(container_base_r, 32'd1);
                        container_dmem_we_r      <= 1'b1;
                        container_dmem_wdata_r   <= {124'b0, PY_TAG_TUPLE};
                        container_dmem_pending_r <= 1'b1;
                        container_probe_r        <= 32'd5;
                    end
                    default: begin
                        // Exception object ready. active_exc_r is set only on
                        // table miss (fatal) or by PUSH_EXC_INFO on a hit.
                        tos_r              <= tos_r - RF_AW'(1);
                        container_tag_r    <= PY_TAG_OBJECT;
                        container_val_r    <= {{96{1'b0}}, container_base_r};
                        container_dmem_addr_r    <= pycore_code_field_val_addr(
                            cur_code_r, PYCORE_CODE_FIELD_CO_EXCEPTIONTABLE);
                        container_dmem_we_r      <= 1'b0;
                        container_dmem_pending_r <= 1'b1;
                        container_phase_r        <= CP_VAL;
                    end
                endcase
            end
        end

        CP_VAL: begin
            if (!container_dmem_pending_r) begin
                // An ordinary-frame unwind uses call_exc_pending_r only to
                // route S_RETURN back here.  Ownership is now CONT_RAISE's.
                call_exc_pending_r      <= 1'b0;
                container_call_exc_unwind_r <= 1'b0;
                container_buf_r        <= container_rd_data_r[31:0];
                container_slot_count_r <= container_rd_data_r[95:64];
                container_dmem_addr_r    <= pycore_tuple_tag_addr(
                    cur_code_r, PYCORE_CODE_FIELD_CO_EXCEPTIONTABLE);
                container_dmem_we_r      <= 1'b0;
                container_dmem_pending_r <= 1'b1;
                container_phase_r        <= CP_TAG;
            end
        end

        CP_TAG: begin
            if (!container_dmem_pending_r) begin
                if (container_rd_data_r[3:0] != PY_TAG_TUPLE) begin
                    container_type_trap_r <= 1'b1;
                end else if (container_slot_count_r == 32'd0) begin
                    if (container_call_active_r &&
                        (frame_active_depth ==
                         container_call_target_depth_r)) begin
                        // §6.1.1: protocol-launched CALL → resume container.
                        call_exc_handle_r <= pycore_make_entry(
                            PY_TAG_OBJECT, container_val_r);
                        call_exc_type_r <= raise_type_entry_r;
                        call_exc_pending_r <= 1'b1;
                        container_call_exc_unwind_r <= 1'b1;
                        container_call_returning_r <= 1'b1;
                        call_sent_r <= 1'b0;
                        frame_dmem_pending_r <= 1'b0;
                        return_phase_r <= 3'd0;
                        container_dmem_pending_r <= 1'b0;
                        fetch_skip_r <= 1'b1;
                        container_phase_r <= CP_DONE;
                    end else if (frame_active_depth > 0) begin
                        // Ordinary Python CALL: preserve the built exception,
                        // pop through S_RETURN, then walk the caller table.
                        call_exc_handle_r <= pycore_make_entry(
                            PY_TAG_OBJECT, container_val_r);
                        call_exc_pending_r <= 1'b1;
                        container_call_exc_unwind_r <= 1'b1;
                        container_call_returning_r <= 1'b0;
                        call_sent_r <= 1'b0;
                        frame_dmem_pending_r <= 1'b0;
                        return_phase_r <= 3'd0;
                        container_dmem_pending_r <= 1'b0;
                        fetch_skip_r <= 1'b1;
                        container_phase_r <= CP_DONE;
                    end else begin
                        active_exc_r <= pycore_make_entry(
                            PY_TAG_OBJECT, container_val_r);
                        active_exc_valid_r <= 1'b1;
                        container_raise_trap_r <= 1'b1;
                        fetch_skip_r <= 1'b1;
                        container_phase_r <= CP_DONE;
                    end
                end else begin
                    container_probe_r        <= 32'd0;
                    container_order_idx_r    <= 32'd0;
                    container_order_len_r    <= 64'd0;
                    container_insert_new_r   <= 1'b1;
                    container_dmem_addr_r    <= pycore_tuple_val_addr(
                        container_buf_r, 32'd0);
                    container_dmem_we_r      <= 1'b0;
                    container_dmem_pending_r <= 1'b1;
                    container_phase_r        <= CP_NAME_VAL;
                end
            end
        end

        CP_NAME_VAL: begin
            if (!container_dmem_pending_r) begin
                container_order_shift_val_r <= container_rd_data_r;
                container_dmem_addr_r    <= pycore_tuple_tag_addr(
                    container_buf_r, container_probe_r);
                container_dmem_we_r      <= 1'b0;
                container_dmem_pending_r <= 1'b1;
                container_phase_r        <= CP_NAME_TAG;
            end
        end

        CP_NAME_TAG: begin
            if (!container_dmem_pending_r) begin
                if (container_rd_data_r[3:0] != PY_TAG_INT) begin
                    container_type_trap_r <= 1'b1;
                end else begin
                    // 6-bit varint (CPython): low 6 data bits, bit6 = continue.
                    if (container_insert_new_r) begin
                        container_order_len_r <=
                            {58'b0, container_order_shift_val_r[5:0]};
                    end else begin
                        container_order_len_r <=
                            (container_order_len_r << 6) |
                            {58'b0, container_order_shift_val_r[5:0]};
                    end
                    container_insert_new_r <= 1'b0;
                    container_probe_r      <= container_probe_r + 32'd1;

                    if (container_order_shift_val_r[6]) begin
                        if ((container_probe_r + 32'd1) >=
                                container_slot_count_r) begin
                            if (container_call_active_r &&
                                (frame_active_depth ==
                                 container_call_target_depth_r)) begin
                                // §6.1.1: protocol-launched CALL → resume container.
                                call_exc_handle_r <= pycore_make_entry(
                                    PY_TAG_OBJECT, container_val_r);
                                call_exc_type_r <= raise_type_entry_r;
                                call_exc_pending_r <= 1'b1;
                                container_call_exc_unwind_r <= 1'b1;
                                container_call_returning_r <= 1'b1;
                                call_sent_r <= 1'b0;
                                frame_dmem_pending_r <= 1'b0;
                                return_phase_r <= 3'd0;
                                container_dmem_pending_r <= 1'b0;
                                fetch_skip_r <= 1'b1;
                                container_phase_r <= CP_DONE;
                            end else if (frame_active_depth > 0) begin
                                call_exc_handle_r <= pycore_make_entry(
                                    PY_TAG_OBJECT, container_val_r);
                                call_exc_pending_r <= 1'b1;
                                container_call_exc_unwind_r <= 1'b1;
                                container_call_returning_r <= 1'b0;
                                call_sent_r <= 1'b0;
                                frame_dmem_pending_r <= 1'b0;
                                return_phase_r <= 3'd0;
                                container_dmem_pending_r <= 1'b0;
                                fetch_skip_r <= 1'b1;
                                container_phase_r <= CP_DONE;
                            end else begin
                                active_exc_r <= pycore_make_entry(
                                    PY_TAG_OBJECT, container_val_r);
                                active_exc_valid_r <= 1'b1;
                                container_raise_trap_r <= 1'b1;
                                fetch_skip_r <= 1'b1;
                                container_phase_r <= CP_DONE;
                            end
                        end else begin
                            container_dmem_addr_r    <= pycore_tuple_val_addr(
                                container_buf_r, container_probe_r + 32'd1);
                            container_dmem_we_r      <= 1'b0;
                            container_dmem_pending_r <= 1'b1;
                            container_phase_r        <= CP_NAME_VAL;
                        end
                    end else begin
                        // Varint complete — use updated accumulator next cycle
                        // via container_finishing_r handshake into CP_LIST_BUF.
                        container_finishing_r <= 1'b1;
                        container_phase_r     <= CP_LIST_BUF;
                    end
                end
            end
        end

        // Apply completed varint to the current entry field.
        CP_LIST_BUF: begin
            if (container_finishing_r) begin
                container_finishing_r <= 1'b0;
                unique case (container_order_idx_r[1:0])
                    2'd0: begin
                        container_range_start_r <=
                            {96'b0, container_order_len_r[31:0]};
                        container_order_idx_r <= 32'd1;
                    end
                    2'd1: begin
                        container_range_stop_r <= container_range_start_r +
                            {96'b0, container_order_len_r[31:0]};
                        container_order_idx_r <= 32'd2;
                    end
                    2'd2: begin
                        container_range_step_r <=
                            {96'b0, container_order_len_r[31:0]};
                        container_order_idx_r <= 32'd3;
                    end
                    default: begin
                        container_used_r      <= container_order_len_r;
                        container_order_idx_r <= 32'd0;
                        container_phase_r     <= CP_LIST_WB;
                    end
                endcase
                if (container_order_idx_r[1:0] != 2'd3) begin
                    if (container_probe_r >= container_slot_count_r) begin
                        if (container_call_active_r &&
                            (frame_active_depth ==
                             container_call_target_depth_r)) begin
                            // §6.1.1: protocol-launched CALL → resume container.
                            call_exc_handle_r <= pycore_make_entry(
                                PY_TAG_OBJECT, container_val_r);
                            call_exc_type_r <= raise_type_entry_r;
                            call_exc_pending_r <= 1'b1;
                            container_call_exc_unwind_r <= 1'b1;
                            container_call_returning_r <= 1'b1;
                            call_sent_r <= 1'b0;
                            frame_dmem_pending_r <= 1'b0;
                            return_phase_r <= 3'd0;
                            container_dmem_pending_r <= 1'b0;
                            fetch_skip_r <= 1'b1;
                            container_phase_r <= CP_DONE;
                        end else if (frame_active_depth > 0) begin
                            call_exc_handle_r <= pycore_make_entry(
                                PY_TAG_OBJECT, container_val_r);
                            call_exc_pending_r <= 1'b1;
                            container_call_exc_unwind_r <= 1'b1;
                            container_call_returning_r <= 1'b0;
                            call_sent_r <= 1'b0;
                            frame_dmem_pending_r <= 1'b0;
                            return_phase_r <= 3'd0;
                            container_dmem_pending_r <= 1'b0;
                            fetch_skip_r <= 1'b1;
                            container_phase_r <= CP_DONE;
                        end else begin
                            active_exc_r <= pycore_make_entry(
                                PY_TAG_OBJECT, container_val_r);
                            active_exc_valid_r <= 1'b1;
                            container_raise_trap_r <= 1'b1;
                            fetch_skip_r <= 1'b1;
                            container_phase_r <= CP_DONE;
                        end
                    end else begin
                        container_order_len_r    <= 64'd0;
                        container_insert_new_r   <= 1'b1;
                        container_dmem_addr_r    <= pycore_tuple_val_addr(
                            container_buf_r, container_probe_r);
                        container_dmem_we_r      <= 1'b0;
                        container_dmem_pending_r <= 1'b1;
                        container_phase_r        <= CP_NAME_VAL;
                    end
                end
            end
        end

        // Match check after depth_lasti.
        CP_LIST_WB: begin
            if ((call_entry_slot_r[31:0] <= cur_pc_r) &&
                (container_range_start_r[31:0] <=
                    (cur_pc_r - call_entry_slot_r[31:0])) &&
                ((cur_pc_r - call_entry_slot_r[31:0]) <
                    container_range_stop_r[31:0])) begin
                if (container_used_r[0]) begin
                    container_wb_we_r   <= 1'b1;
                    container_wb_addr_r <=
                        cur_locals_base_r + RF_AW'(call_nlocals_r) +
                        RF_AW'(container_used_r[16:1]);
                    container_wb_data_r <= pycore_make_entry(
                        PY_TAG_INT,
                        {96'b0, cur_pc_r - call_entry_slot_r[31:0]});
                    tos_r <= cur_locals_base_r + RF_AW'(call_nlocals_r) +
                             RF_AW'(container_used_r[16:1]) + RF_AW'(1);
                    container_phase_r <= CP_ITEM_WB;
                end else begin
                    container_wb_we_r   <= 1'b1;
                    container_wb_addr_r <=
                        cur_locals_base_r + RF_AW'(call_nlocals_r) +
                        RF_AW'(container_used_r[16:1]);
                    container_wb_data_r <= pycore_make_entry(
                        PY_TAG_OBJECT, container_val_r);
                    tos_r <= cur_locals_base_r + RF_AW'(call_nlocals_r) +
                             RF_AW'(container_used_r[16:1]) + RF_AW'(1);
                    redirect_pending_r <= 1'b1;
                    redirect_tgt_r     <= call_entry_slot_r[31:0] +
                                          container_range_step_r[31:0];
                    fetch_skip_r       <= 1'b1;
                    container_phase_r  <= CP_DONE;
                end
            end else if (container_probe_r >= container_slot_count_r) begin
                if (container_call_active_r &&
                    (frame_active_depth ==
                     container_call_target_depth_r)) begin
                    // §6.1.1: protocol-launched CALL → resume container.
                    call_exc_handle_r <= pycore_make_entry(
                        PY_TAG_OBJECT, container_val_r);
                    call_exc_type_r <= raise_type_entry_r;
                    call_exc_pending_r <= 1'b1;
                    container_call_exc_unwind_r <= 1'b1;
                    container_call_returning_r <= 1'b1;
                    call_sent_r <= 1'b0;
                    frame_dmem_pending_r <= 1'b0;
                    return_phase_r <= 3'd0;
                    container_dmem_pending_r <= 1'b0;
                    fetch_skip_r <= 1'b1;
                    container_phase_r <= CP_DONE;
                end else if (frame_active_depth > 0) begin
                    call_exc_handle_r <= pycore_make_entry(
                        PY_TAG_OBJECT, container_val_r);
                    call_exc_pending_r <= 1'b1;
                    container_call_exc_unwind_r <= 1'b1;
                    container_call_returning_r <= 1'b0;
                    call_sent_r <= 1'b0;
                    frame_dmem_pending_r <= 1'b0;
                    return_phase_r <= 3'd0;
                    container_dmem_pending_r <= 1'b0;
                    fetch_skip_r <= 1'b1;
                    container_phase_r <= CP_DONE;
                end else begin
                    active_exc_r <= pycore_make_entry(
                        PY_TAG_OBJECT, container_val_r);
                    active_exc_valid_r <= 1'b1;
                    container_raise_trap_r <= 1'b1;
                    fetch_skip_r <= 1'b1;
                    container_phase_r <= CP_DONE;
                end
            end else begin
                container_order_idx_r    <= 32'd0;
                container_order_len_r    <= 64'd0;
                container_insert_new_r   <= 1'b1;
                container_dmem_addr_r    <= pycore_tuple_val_addr(
                    container_buf_r, container_probe_r);
                container_dmem_we_r      <= 1'b0;
                container_dmem_pending_r <= 1'b1;
                container_phase_r        <= CP_NAME_VAL;
            end
        end

        CP_ITEM_WB: begin
            container_wb_we_r   <= 1'b1;
            container_wb_addr_r <= RF_AW'({2'b0, tos_r});
            container_wb_data_r <= pycore_make_entry(
                PY_TAG_OBJECT, container_val_r);
            tos_r              <= tos_r + RF_AW'(1);
            redirect_pending_r <= 1'b1;
            redirect_tgt_r     <= call_entry_slot_r[31:0] +
                                  container_range_step_r[31:0];
            fetch_skip_r       <= 1'b1;
            container_phase_r  <= CP_DONE;
        end

        CP_DONE: ;

        default: container_phase_r <= CP_DONE;
    endcase
end
