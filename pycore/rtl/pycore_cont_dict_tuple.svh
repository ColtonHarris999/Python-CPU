// TUPLE dict-key content hash + element rich-eq.
// Included inside CONT_STORE/SUBSCR/CONTAINS_DICT unique case tables.
//
// Hash: acc starts as length; each scalar element mixes
//   acc = acc * 33 ^ pycore_dict_key_hash(elem).
// Eq: walk both tuples; match sets container_tuple_eq_hit_r and returns
// to CP_DICT_CHK_VAL. Mismatch continues the open-addressing probe.

                                CP_DICT_TUPLE_HASH_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_list_hdr_r <= container_rd_data_r;
                                        container_dmem_addr_r <=
                                            pycore_tuple_tag_addr(
                                                container_val_r[31:0],
                                                container_src_idx_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_TUPLE_HASH_TAG;
                                    end
                                end

                                CP_DICT_TUPLE_HASH_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        if (!pycore_dict_tuple_elem_tag_ok(
                                                container_rd_data_r[3:0])) begin
                                            container_type_trap_r <= 1'b1;
                                        end else begin
                                            begin
                                                logic [31:0] mixed;
                                                logic [31:0] next_idx;
                                                mixed = pycore_dict_tuple_hash_mix(
                                                    container_probe_r,
                                                    pycore_dict_key_hash(
                                                        container_rd_data_r[3:0],
                                                        container_list_hdr_r));
                                                next_idx = container_src_idx_r + 32'd1;
                                                if (next_idx >= container_src_len_r) begin
                                                    container_probe_r <=
                                                        mixed & (container_slot_count_r
                                                                 - 32'd1);
                                                    container_probe_n_r <= 32'd0;
                                                    container_dmem_addr_r <=
                                                        pycore_dict_ktag_addr(
                                                            container_buf_r,
                                                            mixed & (container_slot_count_r
                                                                     - 32'd1));
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                    container_phase_r <= CP_DICT_PROBE;
                                                end else begin
                                                    container_probe_r   <= mixed;
                                                    container_src_idx_r <= next_idx;
                                                    container_dmem_addr_r <=
                                                        pycore_tuple_val_addr(
                                                            container_val_r[31:0],
                                                            next_idx);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                    container_phase_r <=
                                                        CP_DICT_TUPLE_HASH_VAL;
                                                end
                                            end
                                        end
                                    end
                                end

                                CP_DICT_TUPLE_EQ_A_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_list_hdr_r <= container_rd_data_r;
                                        container_dmem_addr_r <=
                                            pycore_tuple_tag_addr(
                                                container_val_r[31:0],
                                                container_src_idx_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_TUPLE_EQ_A_TAG;
                                    end
                                end

                                CP_DICT_TUPLE_EQ_A_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_order_shift_tag_r <=
                                            container_rd_data_r[3:0];
                                        container_dmem_addr_r <=
                                            pycore_tuple_val_addr(
                                                container_src_buf_r,
                                                container_src_idx_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_TUPLE_EQ_B_VAL;
                                    end
                                end

                                CP_DICT_TUPLE_EQ_B_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_order_shift_val_r <=
                                            container_rd_data_r;
                                        container_dmem_addr_r <=
                                            pycore_tuple_tag_addr(
                                                container_src_buf_r,
                                                container_src_idx_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_TUPLE_EQ_B_TAG;
                                    end
                                end

                                CP_DICT_TUPLE_EQ_B_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        if (!pycore_dict_key_rich_eq(
                                                container_order_shift_tag_r,
                                                container_list_hdr_r,
                                                container_rd_data_r[3:0],
                                                container_order_shift_val_r)) begin
                                            container_probe_r <= cont_probe_next;
                                            container_dmem_addr_r <=
                                                pycore_dict_ktag_addr(
                                                    container_buf_r, cont_probe_next);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_PROBE;
                                        end else if (container_src_idx_r + 32'd1
                                                     >= container_src_len_r) begin
                                            container_tuple_eq_hit_r <= 1'b1;
                                            container_phase_r <= CP_DICT_CHK_VAL;
                                        end else begin
                                            container_src_idx_r <=
                                                container_src_idx_r + 32'd1;
                                            container_dmem_addr_r <=
                                                pycore_tuple_val_addr(
                                                    container_val_r[31:0],
                                                    container_src_idx_r + 32'd1);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <=
                                                CP_DICT_TUPLE_EQ_A_VAL;
                                        end
                                    end
                                end
