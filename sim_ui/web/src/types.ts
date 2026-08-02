export type TaggedValue = {
  tag: string;
  tag_id: number;
  raw: string;
  display: string;
  contaminated: boolean | null;
  kind: string | null;
  addr: number | null;
};

export type FrameInfo = {
  depth: number;
  pc_return: number | null;
  tos_base: number;
  locals_base: number;
  code_addr: number;
  current: boolean;
  func: string | null;
  locals: Record<string, TaggedValue>;
};

export type EventInfo = {
  step: number;
  cycle: number;
  kind: string;
  code: number;
  code_name: string | null;
  recoverable: boolean;
  pc: number;
  opcode: string;
  arg: number;
  mem_owner: string;
};

export type StepSnapshot = {
  step: number;
  cycle: number;
  pc: number;
  opcode: string;
  opcode_id: number;
  oparg: number;
  state: string;
  tos: number;
  locals_base: number;
  frame_depth: number;
  mem_owner: "PYCORE" | "EXCORE" | string;
  heap_ptr: number;
  cur_code: number;
  stack: TaggedValue[];
  locals_window: TaggedValue[];
  frames: FrameInfo[];
  events: EventInfo[];
  excore: { active: boolean; mailbox: unknown };
};

export type DisasmRow = {
  pc: number;
  opcode: string;
  opcode_id: number;
  oparg: number;
  text: string;
  is_cache: boolean;
};

export type EndInfo = {
  status: string;
  cycles: number;
  opcodes: number;
  trap_req_count: number;
  trap_code: number | null;
  trap_name: string | null;
  return_value: TaggedValue | null;
  expected_match: boolean | null;
  cpo: number | null;
};

export type SessionResult = {
  id: string;
  status: string;
  error?: string | null;
  step_count?: number;
  event_count?: number;
  disasm?: DisasmRow[];
  end?: EndInfo;
  result?: {
    expected?: {
      available?: boolean;
      host_display?: string;
      error?: string;
    };
    end?: EndInfo;
  };
};

export type Example = {
  id: string;
  title: string;
  path: string;
  source: string;
};
