// Exception-handler opcodes (§7.3 / §7.6): PUSH_EXC_INFO, CHECK_EXC_MATCH,
// POP_EXCEPT, RERAISE. Uses pycore_exc_stack for nested active-exc contexts.
CONT_PUSH_EXC_INFO: begin
    unique case (container_phase_r)
        CP_INIT: begin
            // One-cycle push request; save prior active_exc onto dmem.
            exc_push_valid_r     <= 1'b1;
            exc_push_prev_ptr_r  <= exc_head;
            exc_push_exc_valid_r <= active_exc_valid_r;
            exc_push_exc_tag_r   <= pycore_get_tag(active_exc_r);
            exc_push_exc_addr_r  <= pycore_get_val(active_exc_r)[63:0];
            container_phase_r    <= CP_HDR;
        end
        CP_HDR: begin
            exc_push_valid_r <= 1'b0;
            if (exc_push_ready) begin
                if (exc_push_fault) begin
                    container_mem_fault_r <= 1'b1;
                end else begin
                    // Stack: [exc] → [prev_or_none, exc]; active ← TOS exc.
                    container_wb_we_r   <= 1'b1;
                    container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(1));
                    if (active_exc_valid_r) begin
                        container_wb_data_r <= active_exc_r;
                    end else begin
                        container_wb_data_r <= pycore_make_control(PY_CTL_NONE);
                    end
                    active_exc_r       <= rs1_r; // latched TOS exc
                    active_exc_valid_r <= 1'b1;
                    container_phase_r  <= CP_VAL;
                end
            end
        end
        CP_VAL: begin
            // Push the exception above prev.
            container_wb_we_r   <= 1'b1;
            container_wb_addr_r <= RF_AW'({2'b0, tos_r});
            container_wb_data_r <= rs1_r;
            tos_r              <= tos_r + RF_AW'(1);
            fetch_skip_r       <= 1'b1;
            container_phase_r  <= CP_DONE;
        end
        CP_DONE: ;
        default: container_phase_r <= CP_DONE;
    endcase
end

CONT_CHECK_EXC_MATCH: begin
    unique case (container_phase_r)
        CP_INIT: begin
            // TOS = handler type or tuple (rs1); TOS-1 = exception instance.
            // Read OBK_EXCEPTION.field0 (raised type) from active_exc_r.
            if (!active_exc_valid_r ||
                (pycore_get_tag(active_exc_r) != PY_TAG_OBJECT)) begin
                container_type_trap_r <= 1'b1;
            end else begin
                container_src_is_tuple_r <= 1'b0;
                container_count_r        <= 7'd0;
                container_idx_r          <= 7'd0;
                container_dmem_addr_r    <= pycore_obj_field_val_addr(
                    pycore_get_val(active_exc_r)[31:0], 32'd0);
                container_dmem_we_r      <= 1'b0;
                container_dmem_pending_r <= 1'b1;
                container_phase_r        <= CP_VAL;
            end
        end
        CP_VAL: begin
            if (!container_dmem_pending_r) begin
                container_val_r <= container_rd_data_r; // raised type value
                container_dmem_addr_r    <= pycore_obj_field_tag_addr(
                    pycore_get_val(active_exc_r)[31:0], 32'd0);
                container_dmem_we_r      <= 1'b0;
                container_dmem_pending_r <= 1'b1;
                container_phase_r        <= CP_TAG;
            end
        end
        CP_TAG: begin
            if (!container_dmem_pending_r) begin
                container_tag_r <= container_rd_data_r[3:0]; // raised type tag
                if ((container_rd_data_r[3:0] == cont_rs1_tag) &&
                    (container_val_r == cont_rs1_val)) begin
                    // Identity: except T: where T is the raised type.
                    container_wb_data_r <= pycore_make_entry(
                        PY_TAG_BOOL, {{(PYCORE_VAL_WIDTH-1){1'b0}}, 1'b1});
                    container_wb_we_r   <= 1'b1;
                    container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(1));
                    fetch_skip_r        <= 1'b1;
                    container_phase_r   <= CP_DONE;
                end else if (cont_rs1_tag == PY_TAG_TUPLE) begin
                    if (pycore_tuple_size(cont_rs1_val) > 64'd8) begin
                        container_type_trap_r <= 1'b1;
                    end else if (pycore_tuple_size(cont_rs1_val) == 64'd0) begin
                        container_wb_data_r <= pycore_make_entry(
                            PY_TAG_BOOL, {(PYCORE_VAL_WIDTH){1'b0}});
                        container_wb_we_r   <= 1'b1;
                        container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(1));
                        fetch_skip_r        <= 1'b1;
                        container_phase_r   <= CP_DONE;
                    end else begin
                        container_src_is_tuple_r <= 1'b1;
                        container_buf_r          <= cont_rs1_val[31:0];
                        container_src_len_r      <= pycore_tuple_size(cont_rs1_val)[31:0];
                        container_idx_r          <= 7'd0;
                        container_dmem_addr_r    <= pycore_tuple_val_addr(
                            cont_rs1_val[31:0], 32'd0);
                        container_dmem_we_r      <= 1'b0;
                        container_dmem_pending_r <= 1'b1;
                        container_phase_r        <= CP_HDR;
                    end
                end else if (cont_rs1_tag != PY_TAG_OBJECT) begin
                    container_type_trap_r <= 1'b1;
                end else begin
                    // Subclass: walk raised_type.tp_base (depth 8).
                    container_src_is_tuple_r <= 1'b0;
                    container_list_hdr_r     <= cont_rs1_val;
                    container_probe_tag_r    <= cont_rs1_tag;
                    container_count_r        <= 7'd0;
                    container_base_r         <= container_val_r[31:0];
                    container_dmem_addr_r    <= pycore_obj_field_val_addr(
                        container_val_r[31:0], 32'd1);
                    container_dmem_we_r      <= 1'b0;
                    container_dmem_pending_r <= 1'b1;
                    container_phase_r        <= CP_ATTR_TYPE;
                end
            end
        end
        CP_HDR: begin
            // Tuple element VALUE.
            if (!container_dmem_pending_r) begin
                container_list_hdr_r     <= container_rd_data_r;
                container_dmem_addr_r    <= pycore_tuple_tag_addr(
                    container_buf_r, {25'b0, container_idx_r});
                container_dmem_we_r      <= 1'b0;
                container_dmem_pending_r <= 1'b1;
                container_phase_r        <= CP_LIST_BUF;
            end
        end
        CP_LIST_BUF: begin
            // Tuple element TAG. Nested tuples and non-types → TYPE.
            if (!container_dmem_pending_r) begin
                if ((container_rd_data_r[3:0] == PY_TAG_TUPLE) ||
                    (container_rd_data_r[3:0] != PY_TAG_OBJECT)) begin
                    container_type_trap_r <= 1'b1;
                end else begin
                    container_probe_tag_r <= container_rd_data_r[3:0];
                    if ((container_rd_data_r[3:0] == container_tag_r) &&
                        (container_list_hdr_r == container_val_r)) begin
                        container_wb_data_r <= pycore_make_entry(
                            PY_TAG_BOOL, {{(PYCORE_VAL_WIDTH-1){1'b0}}, 1'b1});
                        container_wb_we_r   <= 1'b1;
                        container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(1));
                        fetch_skip_r        <= 1'b1;
                        container_phase_r   <= CP_DONE;
                    end else begin
                        container_count_r        <= 7'd0;
                        container_base_r         <= container_val_r[31:0];
                        container_dmem_addr_r    <= pycore_obj_field_val_addr(
                            container_val_r[31:0], 32'd1);
                        container_dmem_we_r      <= 1'b0;
                        container_dmem_pending_r <= 1'b1;
                        container_phase_r        <= CP_ATTR_TYPE;
                    end
                end
            end
        end
        CP_ATTR_TYPE: begin
            // tp_base VALUE of the type at container_base_r.
            if (!container_dmem_pending_r) begin
                container_order_shift_val_r <= container_rd_data_r;
                container_dmem_addr_r       <= pycore_obj_field_tag_addr(
                    container_base_r, 32'd1);
                container_dmem_we_r         <= 1'b0;
                container_dmem_pending_r    <= 1'b1;
                container_phase_r           <= CP_ATTR_TDICT;
            end
        end
        CP_ATTR_TDICT: begin
            // tp_base TAG. Compare parent to the current handler.
            if (!container_dmem_pending_r) begin
                if (pycore_is_none(
                        container_rd_data_r[3:0], container_order_shift_val_r)) begin
                    if (container_src_is_tuple_r &&
                        ({25'b0, container_idx_r} + 32'd1 < container_src_len_r)) begin
                        container_idx_r          <= container_idx_r + 7'd1;
                        container_dmem_addr_r    <= pycore_tuple_val_addr(
                            container_buf_r,
                            {25'b0, container_idx_r} + 32'd1);
                        container_dmem_we_r      <= 1'b0;
                        container_dmem_pending_r <= 1'b1;
                        container_phase_r        <= CP_HDR;
                    end else begin
                        container_wb_data_r <= pycore_make_entry(
                            PY_TAG_BOOL, {(PYCORE_VAL_WIDTH){1'b0}});
                        container_wb_we_r   <= 1'b1;
                        container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(1));
                        fetch_skip_r        <= 1'b1;
                        container_phase_r   <= CP_DONE;
                    end
                end else if ((container_rd_data_r[3:0] == container_probe_tag_r) &&
                             (container_order_shift_val_r == container_list_hdr_r)) begin
                    container_wb_data_r <= pycore_make_entry(
                        PY_TAG_BOOL, {{(PYCORE_VAL_WIDTH-1){1'b0}}, 1'b1});
                    container_wb_we_r   <= 1'b1;
                    container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(1));
                    fetch_skip_r        <= 1'b1;
                    container_phase_r   <= CP_DONE;
                end else if (container_count_r >= 7'd7) begin
                    if (container_src_is_tuple_r &&
                        ({25'b0, container_idx_r} + 32'd1 < container_src_len_r)) begin
                        container_idx_r          <= container_idx_r + 7'd1;
                        container_dmem_addr_r    <= pycore_tuple_val_addr(
                            container_buf_r,
                            {25'b0, container_idx_r} + 32'd1);
                        container_dmem_we_r      <= 1'b0;
                        container_dmem_pending_r <= 1'b1;
                        container_phase_r        <= CP_HDR;
                    end else begin
                        container_wb_data_r <= pycore_make_entry(
                            PY_TAG_BOOL, {(PYCORE_VAL_WIDTH){1'b0}});
                        container_wb_we_r   <= 1'b1;
                        container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(1));
                        fetch_skip_r        <= 1'b1;
                        container_phase_r   <= CP_DONE;
                    end
                end else begin
                    container_count_r        <= container_count_r + 7'd1;
                    container_base_r         <= container_order_shift_val_r[31:0];
                    container_dmem_addr_r    <= pycore_obj_field_val_addr(
                        container_order_shift_val_r[31:0], 32'd1);
                    container_dmem_we_r      <= 1'b0;
                    container_dmem_pending_r <= 1'b1;
                    container_phase_r        <= CP_ATTR_TYPE;
                end
            end
        end
        CP_DONE: ;
        default: container_phase_r <= CP_DONE;
    endcase
end

CONT_POP_EXCEPT: begin
    unique case (container_phase_r)
        CP_INIT: begin
            // CPython pops TOS (saved prev) while restoring the exc-info
            // chain. Pop the dmem node and drop TOS.
            exc_pop_valid_r   <= 1'b1;
            container_phase_r <= CP_HDR;
        end
        CP_HDR: begin
            exc_pop_valid_r <= 1'b0;
            if (exc_pop_ready) begin
                if (exc_pop_fault) begin
                    container_mem_fault_r <= 1'b1;
                end else begin
                    active_exc_valid_r <= exc_pop_exc_valid;
                    if (exc_pop_exc_valid) begin
                        active_exc_r <= pycore_make_entry(
                            exc_pop_exc_tag, {{64{1'b0}}, exc_pop_exc_addr});
                    end else begin
                        active_exc_r <= '0;
                    end
                    tos_r             <= tos_r - RF_AW'(1);
                    fetch_skip_r      <= 1'b1;
                    container_phase_r <= CP_DONE;
                end
            end
        end
        CP_DONE: ;
        default: container_phase_r <= CP_DONE;
    endcase
end

CONT_RERAISE: begin
    unique case (container_phase_r)
        CP_INIT: begin
            // TOS = exception instance. Cleanup bytecode runs POP_EXCEPT
            // before RERAISE 1, so do not dmem-pop here — just re-enter the
            // table walk (oparg selects lasti below TOS in CPython; v1
            // ignores lasti for PC rewrite).
            container_tag_r   <= pycore_get_tag(rs1_r);
            container_val_r   <= pycore_get_val(rs1_r);
            tos_r             <= tos_r - RF_AW'(1);
            container_base_r  <= pycore_get_val(rs1_r)[31:0];
            container_dmem_addr_r    <= pycore_code_field_val_addr(
                cur_code_r, PYCORE_CODE_FIELD_CO_EXCEPTIONTABLE);
            container_dmem_we_r      <= 1'b0;
            container_dmem_pending_r <= 1'b1;
            container_op_r           <= CONT_RAISE;
            container_phase_r        <= CP_VAL;
        end
        default: container_phase_r <= CP_DONE;
    endcase
end
