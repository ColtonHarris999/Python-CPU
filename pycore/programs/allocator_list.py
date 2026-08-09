# pycore-inject: HEAP_LIST_CAPACITY CAPACITY
"""CS:APP-style explicit free-list allocator over a list of integer words.

This is the M6 target program: same allocator shape as allocator_bytes.py, but
with bytearray / slices / int.from_bytes replaced by a list of integers and
plain indexing so M1–M5 object/call/class support can be proven without the
M7 builtin subsystem.

WSIZE=1 means one list cell is one "word". Boundary tags, coalescing, and the
explicit free list are otherwise the textbook design.

CAPACITY is rewritten by run_image_test from the live heap budget
(HEAP_LIMIT - HEAP_INIT_PTR) so heap-map changes do not OOM _zeros().
"""

CAPACITY = 32  # placeholder; overwritten when HEAP_LIST_CAPACITY inject runs

WSIZE = 1
DSIZE = 2
MIN_BLOCK = 4  # header + footer + pred + succ (words)
CHUNKSIZE = 64
NULL = 0


def _align(n):
    return (n + (DSIZE - 1)) & ~(DSIZE - 1)


def _zeros(n):
    """Build a zero-filled list without LIST * INT (unsupported in PyCore).

    CPython 3.14 lowers ``[0] * n`` to BINARY_OP NB_MULTIPLY.  PyCore only
    multiplies numeric tags, so M6 builds via inplace LIST_EXTEND of a
    16-zero chunk (excore path).  Callers must pass a multiple of 16.
    """
    z16 = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    out = []
    filled = 0
    while filled < n:
        out += z16
        filled += 16
    return out


class Allocator:
    def __init__(self, capacity):
        self.mem = _zeros(capacity)
        self.mem_max = capacity
        self.brk = 0
        self.free_listp = NULL
        self.heap_listp = NULL
        self._mm_init()

    def _get(self, addr):
        return self.mem[addr]

    def _put(self, addr, val):
        self.mem[addr] = val

    def _pack(self, size, alloc):
        return (size << 1) | (1 if alloc else 0)

    def _size(self, header):
        return header >> 1

    def _allocated(self, header):
        return header & 1

    def _hdrp(self, bp):
        return bp - WSIZE

    def _ftrp(self, bp):
        return bp + self._size(self._get(self._hdrp(bp))) - DSIZE

    def _next_blkp(self, bp):
        return bp + self._size(self._get(self._hdrp(bp)))

    def _prev_blkp(self, bp):
        prev_size = self._size(self._get(bp - DSIZE))
        return bp - prev_size

    def _succ(self, bp):
        return self._get(bp)

    def _pred(self, bp):
        return self._get(bp + WSIZE)

    def _set_succ(self, bp, succ):
        self._put(bp, succ)

    def _set_pred(self, bp, pred):
        self._put(bp + WSIZE, pred)

    def _insert_free(self, bp):
        self._set_succ(bp, self.free_listp)
        self._set_pred(bp, NULL)
        if self.free_listp != NULL:
            self._set_pred(self.free_listp, bp)
        self.free_listp = bp

    def _remove_free(self, bp):
        pred = self._pred(bp)
        succ = self._succ(bp)
        if pred != NULL:
            self._set_succ(pred, succ)
        else:
            self.free_listp = succ
        if succ != NULL:
            self._set_pred(succ, pred)

    def _mm_init(self):
        # Prologue (allocated), epilogue (size-0 allocated).
        if self.brk + 4 > self.mem_max:
            return -1
        self._put(0, self._pack(DSIZE, 1))  # prologue header
        self._put(1, self._pack(DSIZE, 1))  # prologue footer
        self._put(2, self._pack(0, 1))  # epilogue
        self.brk = 3
        self.heap_listp = 2
        self.free_listp = NULL
        return 0

    def _extend_heap(self, words):
        words = _align(words)
        if self.brk + words > self.mem_max:
            return NULL
        bp = self.brk
        # Overwrite old epilogue with a free-block header.
        self._put(self._hdrp(bp), self._pack(words, 0))
        self._put(self._ftrp(bp), self._pack(words, 0))
        # New epilogue.
        self._put(self._hdrp(self._next_blkp(bp)), self._pack(0, 1))
        self.brk = self._hdrp(self._next_blkp(bp)) + WSIZE
        return self._coalesce(bp)

    def _coalesce(self, bp):
        prev_alloc = self._allocated(self._get(self._hdrp(bp) - WSIZE))
        next_hdr = self._get(self._hdrp(self._next_blkp(bp)))
        next_alloc = self._allocated(next_hdr)
        size = self._size(self._get(self._hdrp(bp)))

        if prev_alloc and next_alloc:
            self._insert_free(bp)
            return bp
        if prev_alloc and not next_alloc:
            next_bp = self._next_blkp(bp)
            self._remove_free(next_bp)
            size = size + self._size(next_hdr)
            self._put(self._hdrp(bp), self._pack(size, 0))
            self._put(self._ftrp(bp), self._pack(size, 0))
            self._insert_free(bp)
            return bp
        if (not prev_alloc) and next_alloc:
            prev_bp = self._prev_blkp(bp)
            self._remove_free(prev_bp)
            size = size + self._size(self._get(self._hdrp(prev_bp)))
            self._put(self._ftrp(bp), self._pack(size, 0))
            self._put(self._hdrp(prev_bp), self._pack(size, 0))
            self._insert_free(prev_bp)
            return prev_bp
        # both free
        prev_bp = self._prev_blkp(bp)
        next_bp = self._next_blkp(bp)
        self._remove_free(prev_bp)
        self._remove_free(next_bp)
        size = (
            size
            + self._size(self._get(self._hdrp(prev_bp)))
            + self._size(self._get(self._hdrp(next_bp)))
        )
        self._put(self._hdrp(prev_bp), self._pack(size, 0))
        self._put(self._ftrp(next_bp), self._pack(size, 0))
        self._insert_free(prev_bp)
        return prev_bp

    def _place(self, bp, asize):
        csize = self._size(self._get(self._hdrp(bp)))
        self._remove_free(bp)
        if (csize - asize) >= MIN_BLOCK:
            self._put(self._hdrp(bp), self._pack(asize, 1))
            self._put(self._ftrp(bp), self._pack(asize, 1))
            next_bp = self._next_blkp(bp)
            rem = csize - asize
            self._put(self._hdrp(next_bp), self._pack(rem, 0))
            self._put(self._ftrp(next_bp), self._pack(rem, 0))
            self._insert_free(next_bp)
        else:
            self._put(self._hdrp(bp), self._pack(csize, 1))
            self._put(self._ftrp(bp), self._pack(csize, 1))

    def _find_fit(self, asize):
        bp = self.free_listp
        while bp != NULL:
            if self._size(self._get(self._hdrp(bp))) >= asize:
                return bp
            bp = self._succ(bp)
        return NULL

    def alloc(self, words):
        if words <= 0:
            return -1
        asize = _align(words + DSIZE)  # payload + header/footer
        if asize < MIN_BLOCK:
            asize = MIN_BLOCK
        bp = self._find_fit(asize)
        if bp is NULL or bp == NULL:
            extend = asize
            if extend < CHUNKSIZE:
                extend = CHUNKSIZE
            bp = self._extend_heap(extend)
            if bp == NULL:
                return -1
        self._place(bp, asize)
        return bp

    def free(self, bp):
        if bp == NULL or bp == -1:
            return
        size = self._size(self._get(self._hdrp(bp)))
        self._put(self._hdrp(bp), self._pack(size, 0))
        self._put(self._ftrp(bp), self._pack(size, 0))
        self._coalesce(bp)


def managed_entry():
    a = Allocator(CAPACITY)
    p1 = a.alloc(3)
    p2 = a.alloc(12)
    p3 = a.alloc(3)
    a.free(p1)
    a.free(p3)
    a.free(p2)  # triple coalesce
    big = a.alloc(20)  # must reuse the coalesced run
    return big


managed_entry()
