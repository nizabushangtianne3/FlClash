use crate::api::editor::GuideBlock;
use ropey::{Rope, RopeSlice};

const SCAN_BACK_LIMIT: usize = 500;

pub fn compute_viewport(
    rope: &Rope,
    first_visible: usize,
    last_visible: usize,
    tab_size: usize,
) -> Vec<GuideBlock> {
    let total_lines = rope.len_lines();

    if total_lines == 0 {
        return Vec::new();
    }

    let first = first_visible.min(total_lines.saturating_sub(1));
    let last = last_visible.min(total_lines.saturating_sub(1));
    let scan_start = first.saturating_sub(SCAN_BACK_LIMIT);
    // Nothing below the viewport is drawn, so a block still open at the
    // horizon is reported as ending there instead of scanning the document.
    let horizon = (last + 2).min(total_lines);

    // Every line the pass can land on is measured once here. Ropey's char(i)
    // restarts from the head of the chunk holding it, so reading a line's stats
    // by index would make one pass over a block cost its length squared.
    let stats: Vec<LineStats> = (scan_start..horizon)
        .map(|line_idx| line_stats(&rope.line(line_idx), tab_size))
        .collect();
    let stat = |line_idx: usize| &stats[line_idx - scan_start];

    let mut blocks: Vec<GuideBlock> = Vec::new();

    for line_idx in scan_start..=last {
        let line = stat(line_idx);
        let Some(last_char) = line.last_char else {
            continue;
        };

        if !matches!(last_char, '{' | '(' | '[' | ':') {
            continue;
        }

        let leading_cols = line.leading_columns;
        let indent_level = leading_cols.checked_div(tab_size).unwrap_or(0);

        let mut end_line: usize = line_idx + 1;

        if matches!(last_char, '{' | '(' | '[') {
            let bracket_pos = rope.line_to_char(line_idx) + line.trimmed_len - 1;
            let limit = rope.line_to_char(horizon);
            if let Some(match_pos) = find_matching_bracket_forward(rope, bracket_pos, limit) {
                end_line = rope.char_to_line(match_pos) + 1;
            }
        }

        if end_line <= line_idx + 1 {
            let mut scan = line_idx + 1;
            let mut last_valid = line_idx;
            while scan < horizon {
                let inner = stat(scan);
                if inner.last_char.is_none() {
                    scan += 1;
                    continue;
                }
                if inner.leading_columns <= leading_cols {
                    break;
                }
                last_valid = scan;
                scan += 1;
            }
            end_line = if scan == horizon && horizon < total_lines {
                horizon
            } else {
                last_valid + 1
            };
        }

        if end_line <= line_idx + 1 {
            continue;
        }

        let would_pass = ((line_idx + 1)..(end_line.saturating_sub(1).min(horizon))).any(|check| {
            let inner = stat(check);
            inner.last_char.is_some() && inner.leading_columns <= leading_cols
        });

        if would_pass {
            continue;
        }

        blocks.push(GuideBlock {
            start_line: line_idx as i32,
            end_line: end_line as i32,
            indent_level: indent_level as i32,
            leading_spaces: leading_cols as i32,
        });
    }

    blocks
}

/// One line's length without the break or trailing whitespace, its last char,
/// and the indent it opens with.
struct LineStats {
    trimmed_len: usize,
    last_char: Option<char>,
    leading_columns: usize,
}

fn line_stats(line: &RopeSlice, tab_size: usize) -> LineStats {
    let mut cols = 0;
    let mut trimmed_len = 0;
    let mut last_char = None;
    let mut in_indent = true;
    for (idx, ch) in line.chars().enumerate() {
        if ch == '\n' {
            break;
        }
        if in_indent {
            match ch {
                ' ' => cols += 1,
                '\t' if tab_size > 0 => cols += tab_size - cols % tab_size,
                '\t' => cols += 1,
                _ => in_indent = false,
            }
        }
        if !ch.is_whitespace() {
            trimmed_len = idx + 1;
            last_char = Some(ch);
        }
    }
    LineStats {
        trimmed_len,
        last_char,
        leading_columns: cols,
    }
}

fn find_matching_bracket_forward(
    rope: &Rope,
    open_offset: usize,
    limit_char: usize,
) -> Option<usize> {
    let open = rope.char(open_offset);
    let close = match open {
        '{' => '}',
        '[' => ']',
        '(' => ')',
        _ => return None,
    };
    let mut depth = 1;
    for (i, ch) in rope.chars_at(open_offset + 1).enumerate() {
        let idx = open_offset + 1 + i;
        if idx >= limit_char {
            break;
        }
        if ch == open {
            depth += 1;
        } else if ch == close {
            depth -= 1;
            if depth == 0 {
                return Some(idx);
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn blocks(text: &str, first: usize, last: usize, tab: usize) -> Vec<(i32, i32, i32, i32)> {
        compute_viewport(&Rope::from_str(text), first, last, tab)
            .into_iter()
            .map(|b| (b.start_line, b.end_line, b.indent_level, b.leading_spaces))
            .collect()
    }

    fn content_len(line: &RopeSlice) -> usize {
        let mut len = line.len_chars();
        if len >= 2 && line.char(len - 1) == '\n' && line.char(len - 2) == '\r' {
            len -= 2;
        }
        if len >= 1 && line.char(len - 1) == '\n' {
            len -= 1;
        }
        len
    }

    fn is_blank(line: &RopeSlice, len: usize) -> bool {
        (0..len).all(|i| line.char(i).is_whitespace())
    }

    fn leading_columns(line: &RopeSlice, len: usize, tab_size: usize) -> usize {
        let mut cols: usize = 0;
        for i in 0..len {
            match line.char(i) {
                ' ' => cols += 1,
                '\t' if tab_size > 0 => cols += tab_size - cols % tab_size,
                '\t' => cols += 1,
                _ => break,
            }
        }
        cols
    }

    fn blocks_by_index(
        text: &str,
        first_visible: usize,
        last_visible: usize,
        tab_size: usize,
    ) -> Vec<(i32, i32, i32, i32)> {
        let rope = Rope::from_str(text);
        let total_lines = rope.len_lines();
        if total_lines == 0 {
            return Vec::new();
        }
        let first = first_visible.min(total_lines.saturating_sub(1));
        let last = last_visible.min(total_lines.saturating_sub(1));
        let scan_start = first.saturating_sub(SCAN_BACK_LIMIT);
        let horizon = (last + 2).min(total_lines);
        let mut out = Vec::new();
        for line_idx in scan_start..=last {
            let line_slice = rope.line(line_idx);
            let mut line_len = content_len(&line_slice);
            while line_len > 0 && line_slice.char(line_len - 1).is_whitespace() {
                line_len -= 1;
            }
            if line_len == 0 {
                continue;
            }
            let last_char = line_slice.char(line_len - 1);
            if !matches!(last_char, '{' | '(' | '[' | ':') {
                continue;
            }
            let leading_cols = leading_columns(&line_slice, line_len, tab_size);
            let indent_level = leading_cols.checked_div(tab_size).unwrap_or(0);
            let mut end_line = line_idx + 1;
            if matches!(last_char, '{' | '(' | '[') {
                let bracket_pos = rope.line_to_char(line_idx) + line_len - 1;
                let limit = rope.line_to_char(horizon);
                if let Some(match_pos) = find_matching_bracket_forward(&rope, bracket_pos, limit) {
                    end_line = rope.char_to_line(match_pos) + 1;
                }
            }
            if end_line <= line_idx + 1 {
                let mut scan = line_idx + 1;
                let mut last_valid = line_idx;
                while scan < horizon {
                    let line_slice = rope.line(scan);
                    let nl_len = content_len(&line_slice);
                    if is_blank(&line_slice, nl_len) {
                        scan += 1;
                        continue;
                    }
                    if leading_columns(&line_slice, nl_len, tab_size) <= leading_cols {
                        break;
                    }
                    last_valid = scan;
                    scan += 1;
                }
                end_line = if scan == horizon && horizon < total_lines {
                    horizon
                } else {
                    last_valid + 1
                };
            }
            if end_line <= line_idx + 1 {
                continue;
            }
            let would_pass =
                ((line_idx + 1)..(end_line.saturating_sub(1).min(horizon))).any(|check| {
                    let cl_slice = rope.line(check);
                    let cl_len = content_len(&cl_slice);
                    !is_blank(&cl_slice, cl_len)
                        && leading_columns(&cl_slice, cl_len, tab_size) <= leading_cols
                });
            if would_pass {
                continue;
            }
            out.push((
                line_idx as i32,
                end_line as i32,
                indent_level as i32,
                leading_cols as i32,
            ));
        }
        out
    }

    #[test]
    fn the_iterating_pass_matches_the_indexing_reference() {
        let texts = [
            "proxies:\n  - name: a\n    ws-opts:\n      path: /\n\n  - name: b\nrules:\n  - MATCH,DIRECT\n\n",
            "f(a,\n  b:\n    c\n  d)\n",
            "a:\n\tb:\n\t\tc\n",
            "x {\n  y: [1,\n    2]\n}\n",
            "a:\r\n  b\r\n\r\nc\r\n",
            "one\n",
            "",
            "\n\n\n",
            "a:\n  \n  b\n",
            "deep {\n  a {\n    b: {\n      c\n    }\n  }\n}\n",
            "tab:\n\tone\n\ttwo\nplain: 1\n",
            "  indented:\n    body\n  after\n",
            "closers {\n  inner (\n    x\n  )\n}\nplain\n",
            "\u{feff}\n  a\n",
            "trailing ws:   \n  body\n",
        ];
        for text in texts {
            for (first, last) in [(0, 1), (0, 4), (1, 3), (0, 0), (2, 9)] {
                for tab in [2usize, 4, 0, 1] {
                    assert_eq!(
                        blocks(text, first, last, tab),
                        blocks_by_index(text, first, last, tab),
                        "text={:?} first={} last={} tab={}",
                        text,
                        first,
                        last,
                        tab
                    );
                }
            }
        }
    }

    #[test]
    fn a_block_still_open_at_the_horizon_ends_there() {
        let text = "a {\n  b\n  c\n  d\n  e\n}\n";
        assert_eq!(blocks(text, 0, 1, 2), [(0, 3, 0, 0)]);
    }

    #[test]
    fn a_colon_guides_over_the_block_it_opens() {
        assert_eq!(
            blocks(
                "proxies:\n  - name: a\n    ws-opts:\n      path: /\n\n  - name: b\nrules:\n",
                0,
                7,
                2
            ),
            [(0, 6, 0, 0), (2, 4, 2, 4)]
        );
    }

    #[test]
    fn a_bracket_line_ends_at_its_closing_bracket() {
        assert_eq!(blocks("a {\n  b\n} \nc\n", 0, 3, 2), [(0, 3, 0, 0)]);
    }

    #[test]
    fn nothing_is_guided_when_no_line_opens_a_block() {
        assert!(blocks("a\nb\nc\n", 0, 2, 2).is_empty());
    }
}
