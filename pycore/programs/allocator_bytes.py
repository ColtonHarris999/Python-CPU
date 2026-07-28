"""CS:APP-style explicit free-list allocator over a bytearray heap.

This is the M8 target program. Same boundary-tag / free-list design as
allocator_list.py, but words are 8-byte little-endian cells in a bytearray,
so it needs bytearray, int.from_bytes / int.to_bytes, and (for demos) slices.

Word size WSIZE=8 matches a typical 64-bit CS:APP heap cell.
"""

WSIZE = 8
DSIZE = 16
MIN_BLOCK = 32  # header + footer + pred + succ
CHUNKSIZE = 1 << 12
NULL = 0
HEAP_CAPACITY = 1 << 16


def _align(n):
    return (n + (DSIZE - 1)) & ~(DSIZE - 1)


class Allocator:
    def __init__(self, capacity=HEAP_CAPACITY):
        self.mem = bytearray(capacity)
        self.mem_max = capacity
        self.brk = 0
        self.free_listp = NULL
        self.heap_listp = NULL
        self._mm_init()

    def _get(self, addr):
        return int.from_bytes(self.mem[addr : addr + WSIZE], "little")

    def _put(self, addr, val):
        self.mem[addr : addr + WSIZE] = int(val).to_bytes(WSIZE, "little", signed=False)

    def _pack(self, size, alloc):
        return size | (1 if alloc else 0)

    def _size(self, header):
        return header & ~0x7

    def _allocated(self, header):
        return header & 0x1

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
        if self.brk + (4 * WSIZE) > self.mem_max:
            return -1
        self._put(0, self._pack(DSIZE, 1))
        self._put(WSIZE, self._pack(DSIZE, 1))
        self._put(DSIZE, self._pack(0, 1))
        self.brk = DSIZE + WSIZE
        self.heap_listp = DSIZE
        self.free_listp = NULL
        return 0

    def _extend_heap(self, bytes_):
        bytes_ = _align(bytes_)
        if self.brk + bytes_ > self.mem_max:
            return NULL
        bp = self.brk
        self._put(self._hdrp(bp), self._pack(bytes_, 0))
        self._put(self._ftrp(bp), self._pack(bytes_, 0))
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

    def alloc(self, nbytes):
        if nbytes <= 0:
            return -1
        asize = _align(nbytes + DSIZE)
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
    a = Allocator(HEAP_CAPACITY)
    p1 = a.alloc(24)
    p2 = a.alloc(96)
    p3 = a.alloc(24)
    a.free(p1)
    a.free(p3)
    a.free(p2)
    big = a.alloc(160)
    return big


managed_entry()
