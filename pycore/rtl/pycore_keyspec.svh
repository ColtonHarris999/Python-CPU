// Key specification entry point (accelerator_split_plan.md §6.9).
//
// The function bodies live in pycore_defs.svh, next to the numeric helpers
// they call:
//   pycore_dict_key_hash          hash
//   pycore_dict_key_tag_ok        hashability
//   pycore_dict_key_rich_eq       rich equality
//   pycore_str_need_payload_cmp   payload-compare predicate
//   pycore_elem_eq                element equality for `in`
// pycore/tools/keyspec.py is the host model. tools/gen_key_vectors.py
// emits the vectors both check. This header is what the container
// accelerator includes; it does not define a second copy.

function automatic logic pycore_key_hashable(input logic [3:0] tag);
    pycore_key_hashable = pycore_dict_key_tag_ok(tag);
endfunction
