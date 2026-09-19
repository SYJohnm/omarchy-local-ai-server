#!/usr/bin/env python3
import sys, struct, json

FIXED_SIZES = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8}

def read_str(f):
    (n,) = struct.unpack('<Q', f.read(8))
    return f.read(n).decode('utf-8', errors='replace')

def skip_value(f, vtype):
    if vtype == 8:
        read_str(f)
    elif vtype == 9:
        (elem_type,) = struct.unpack('<I', f.read(4))
        (count,) = struct.unpack('<Q', f.read(8))
        for _ in range(count):
            skip_value(f, elem_type)
    elif vtype in FIXED_SIZES:
        f.read(FIXED_SIZES[vtype])
    else:
        raise ValueError('unknown gguf value type %d' % vtype)

def read_value(f, vtype):
    if vtype == 8:
        return read_str(f)
    if vtype == 7:
        return struct.unpack('<?', f.read(1))[0]
    if vtype == 4:
        return struct.unpack('<I', f.read(4))[0]
    if vtype == 5:
        return struct.unpack('<i', f.read(4))[0]
    if vtype == 10:
        return struct.unpack('<Q', f.read(8))[0]
    if vtype == 6:
        return struct.unpack('<f', f.read(4))[0]
    skip_value(f, vtype)
    return None

WANT = {
    'general.architecture', 'general.name', 'general.basename',
    'general.size_label', 'general.file_type', 'tokenizer.chat_template',
}

# Attention geometry, used to size the KV cache. These keys are prefixed with
# the architecture name ("qwen3moe.block_count", "llama.attention.head_count_kv"),
# which varies per model, so they are matched on suffix and reported under a
# stable, architecture-independent name.
#
# key_length/value_length are frequently absent; when they are, head_dim is
# derived as embedding_length / head_count.
GEOMETRY_SUFFIXES = {
    '.block_count': 'block_count',
    '.attention.head_count_kv': 'head_count_kv',
    '.attention.head_count': 'head_count',
    '.attention.key_length': 'key_length',
    '.attention.value_length': 'value_length',
    '.embedding_length': 'embedding_length',
    '.context_length': 'context_length',
}

def geometry_name(key):
    for suffix, name in GEOMETRY_SUFFIXES.items():
        if key.endswith(suffix):
            return name
    return None

def probe(path):
    out = {}
    with open(path, 'rb') as f:
        magic = f.read(4)
        if magic != b'GGUF':
            return {'error': 'not gguf'}
        struct.unpack('<I', f.read(4))  # version
        tensor_count, kv_count = struct.unpack('<QQ', f.read(16))
        for _ in range(kv_count):
            key = read_str(f)
            (vtype,) = struct.unpack('<I', f.read(4))
            geom = geometry_name(key)
            if key in WANT:
                out[key] = read_value(f, vtype)
            elif geom is not None:
                value = read_value(f, vtype)
                if isinstance(value, int):
                    out[geom] = value
            else:
                skip_value(f, vtype)

        # Tensor descriptors carry no weight data (just name/shape/offset),
        # so scanning all of them to spot an embedded MTP draft head
        # (blk.N.nextn.*) is still metadata-only and fast.
        has_nextn = False
        for _ in range(tensor_count):
            name = read_str(f)
            (n_dims,) = struct.unpack('<I', f.read(4))
            f.read(8 * n_dims)          # dims
            f.read(4)                   # tensor type
            f.read(8)                   # offset
            if '.nextn.' in name:
                has_nextn = True
        out['has_nextn'] = has_nextn
    return out

if __name__ == '__main__':
    result = {}
    for path in sys.argv[1:]:
        try:
            result[path] = probe(path)
        except Exception as e:
            result[path] = {'error': str(e)}
    print(json.dumps(result))
