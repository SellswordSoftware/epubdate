/// The reader's complete fixed-resource policy. Values here are product
/// limits, not properties inferred from a particular EPUB fixture.
pub const Limits = struct {
    max_archive_entries: usize = 64,
    max_archive_filename_bytes: usize = 256,
    compressed_input_bytes: usize = 4 * 1024,
    decoded_output_chunk_bytes: usize = 1024,
    forward_chapter_bytes_per_update: usize = 256,
    reconstruction_bytes_per_update: usize = 2 * 1024,
    prefetch_bytes_per_update: usize = 1024,
    metadata_read_chunk_bytes: usize = 1024,
    max_container_document_bytes: usize = 1024,
    max_package_document_bytes: usize = 64 * 1024,
    max_navigation_document_bytes: usize = 64 * 1024,
    max_xml_tag_bytes: usize = 1024,
    max_xml_entity_bytes: usize = 32,
    page_line_count: usize = 11,
    page_line_bytes: usize = 384,
};

pub const reader = Limits{};

test "resource policy preserves required stream and DEFLATE bounds" {
    const std = @import("std");
    try std.testing.expect(reader.max_archive_entries <= 64);
    try std.testing.expect(reader.max_archive_filename_bytes <= 256);
    try std.testing.expect(reader.compressed_input_bytes >= 1024);
    try std.testing.expect(reader.compressed_input_bytes <= 4 * 1024);
    try std.testing.expectEqual(@as(usize, 256), reader.forward_chapter_bytes_per_update);
    try std.testing.expectEqual(@as(usize, 2 * 1024), reader.reconstruction_bytes_per_update);
    try std.testing.expect(reader.reconstruction_bytes_per_update > reader.forward_chapter_bytes_per_update);
    try std.testing.expect(reader.max_xml_entity_bytes <= reader.max_xml_tag_bytes);
}
