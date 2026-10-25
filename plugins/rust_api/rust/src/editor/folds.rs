use crate::api::editor::RustFoldRange;
use ropey::Rope;

// Mirrors the renderer's per-line fallback for small documents: a bracket
// fold, or for a line ending in ':' the run of deeper-indented lines after
// it, the smaller of the two when a line has both.
pub fn compute_all(rope: &Rope, tab_size: usize) -> Vec<RustFoldRange> {
    let mut bracket = Vec::new();
    let mut indent = Vec::new();
    let mut open: [Vec<i32>; 3] = Default::default();
    let mut open_indent: Vec<(usize, usize)> = Vec::new();
    let mut last_content = 0;

    for (line_idx, line) in rope.lines().enumerate() {
        let mut indent_cols = 0;
        let mut in_indent = true;
        let mut last = None;
        for ch in line.chars() {
            match ch {
                '{' => push_bracket(&mut open, 0, true, line_idx, &mut bracket),
                '}' => push_bracket(&mut open, 0, false, line_idx, &mut bracket),
                '[' => push_bracket(&mut open, 1, true, line_idx, &mut bracket),
                ']' => push_bracket(&mut open, 1, false, line_idx, &mut bracket),
                '(' => push_bracket(&mut open, 2, true, line_idx, &mut bracket),
                ')' => push_bracket(&mut open, 2, false, line_idx, &mut bracket),
                _ => {}
            }
            if in_indent {
                match ch {
                    ' ' => indent_cols += 1,
                    '\t' if tab_size > 0 => indent_cols += tab_size - indent_cols % tab_size,
                    '\t' => indent_cols += 1,
                    _ => in_indent = false,
                }
            }
            // The per-line pass in Dart trims U+FEFF as whitespace.
            if !ch.is_whitespace() && ch != '\u{feff}' {
                last = Some(ch);
            }
        }

        let Some(last_char) = last else {
            continue;
        };
        while let Some(&(start, start_indent)) = open_indent.last() {
            if indent_cols > start_indent {
                break;
            }
            open_indent.pop();
            close(start, last_content, &mut indent);
        }
        if last_char == ':' {
            open_indent.push((line_idx, indent_cols));
        }
        last_content = line_idx;
    }
    for (start, _) in open_indent {
        close(start, last_content, &mut indent);
    }
    merge(bracket, indent)
}

fn push_bracket(
    open: &mut [Vec<i32>; 3],
    kind: usize,
    opens: bool,
    line_idx: usize,
    folds: &mut Vec<RustFoldRange>,
) {
    if opens {
        open[kind].push(line_idx as i32);
    } else if let Some(start_line) = open[kind].pop() {
        if start_line < line_idx as i32 {
            folds.push(RustFoldRange {
                start_line,
                end_line: line_idx as i32,
            });
        }
    }
}

/// Merges the two fold lists, keeping the smaller end when a line produced both.
fn merge(bracket: Vec<RustFoldRange>, indent: Vec<RustFoldRange>) -> Vec<RustFoldRange> {
    // A fold is produced when its block closes, so neither list is ordered.
    let mut folds = bracket;
    folds.extend(indent);
    folds.sort_unstable_by_key(|fold| fold.start_line);
    // The closure visits every adjacent pair, so the merge must stay inside the
    // equality test: a pair merely next to each other is not the same fold.
    folds.dedup_by(|later, earlier| {
        if later.start_line == earlier.start_line {
            earlier.end_line = earlier.end_line.min(later.end_line);
            true
        } else {
            false
        }
    });
    folds
}

fn close(start: usize, end: usize, folds: &mut Vec<RustFoldRange>) {
    if end > start {
        folds.push(RustFoldRange {
            start_line: start as i32,
            end_line: end as i32,
        });
    }
}

/// Finds the bracket that pairs with the one at `target_offset`, stopping the
/// forward scan at `horizon` so a caller that knows where the visible range
/// ends never pays for a pair that sits below it.
pub fn find_matching_bracket(rope: &Rope, target_offset: usize, horizon: usize) -> Option<usize> {
    let len = rope.len_chars();
    if target_offset >= len {
        return None;
    }

    let start_ch: char = rope.char(target_offset);

    let (matcher, search_forward) = match start_ch {
        '{' => ('}', true),
        '[' => (']', true),
        '(' => (')', true),
        '}' => ('{', false),
        ']' => ('[', false),
        ')' => ('(', false),
        _ => return None,
    };

    let mut depth = 1;

    if search_forward {
        let limit = horizon.min(len);
        for (i, ch) in rope.chars_at(target_offset + 1).enumerate() {
            let idx = target_offset + 1 + i;
            if idx >= limit {
                break;
            }
            if ch == start_ch {
                depth += 1;
            } else if ch == matcher {
                depth -= 1;
                if depth == 0 {
                    return Some(idx);
                }
            }
        }
    } else {
        // Walking backwards by index would descend the rope tree once per
        // character; the iterator walks the chunks instead.
        let mut idx = target_offset;
        for ch in rope.chars_at(target_offset).reversed() {
            idx -= 1;
            if ch == start_ch {
                depth += 1;
            } else if ch == matcher {
                depth -= 1;
                if depth == 0 {
                    return Some(idx);
                }
            }
        }
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn folds(text: &str) -> Vec<(i32, i32)> {
        compute_all(&Rope::from_str(text), 2)
            .into_iter()
            .map(|fold| (fold.start_line, fold.end_line))
            .collect()
    }

    fn bracket_folds_by_chars(rope: &Rope) -> Vec<RustFoldRange> {
        let mut folds = Vec::new();
        let mut open: [Vec<i32>; 3] = Default::default();
        let mut line_idx: i32 = 0;
        for ch in rope.chars() {
            let (kind, opens) = match ch {
                '\n' => {
                    line_idx += 1;
                    continue;
                }
                '{' => (0, true),
                '}' => (0, false),
                '[' => (1, true),
                ']' => (1, false),
                '(' => (2, true),
                ')' => (2, false),
                _ => continue,
            };
            if opens {
                open[kind].push(line_idx);
            } else if let Some(start_line) = open[kind].pop() {
                if start_line < line_idx {
                    folds.push(RustFoldRange {
                        start_line,
                        end_line: line_idx,
                    });
                }
            }
        }
        folds
    }

    fn indent_folds_by_line(rope: &Rope, tab_size: usize) -> Vec<RustFoldRange> {
        let mut folds = Vec::new();
        let mut open: Vec<(usize, usize)> = Vec::new();
        let mut last_content = 0;
        for (line_idx, line) in rope.lines().enumerate() {
            let mut indent = 0;
            let mut in_indent = true;
            let mut last = None;
            for ch in line.chars() {
                if in_indent {
                    match ch {
                        ' ' => indent += 1,
                        '\t' if tab_size > 0 => indent += tab_size - indent % tab_size,
                        '\t' => indent += 1,
                        _ => in_indent = false,
                    }
                }
                if !ch.is_whitespace() && ch != '\u{feff}' {
                    last = Some(ch);
                }
            }
            let Some((indent, ends_with_colon)) = last.map(|ch| (indent, ch == ':')) else {
                continue;
            };
            while let Some(&(start, start_indent)) = open.last() {
                if indent > start_indent {
                    break;
                }
                open.pop();
                close(start, last_content, &mut folds);
            }
            if ends_with_colon {
                open.push((line_idx, indent));
            }
            last_content = line_idx;
        }
        for (start, _) in open {
            close(start, last_content, &mut folds);
        }
        folds
    }

    fn folds_by_two_passes(text: &str, tab_size: usize) -> Vec<(i32, i32)> {
        use std::collections::HashMap;
        let rope = Rope::from_str(text);
        let mut ends: HashMap<i32, i32> = HashMap::new();
        for fold in bracket_folds_by_chars(&rope) {
            ends.entry(fold.start_line).or_insert(fold.end_line);
        }
        for fold in indent_folds_by_line(&rope, tab_size) {
            ends.entry(fold.start_line)
                .and_modify(|end| *end = (*end).min(fold.end_line))
                .or_insert(fold.end_line);
        }
        let mut out: Vec<(i32, i32)> = ends.into_iter().collect();
        out.sort_by_key(|(start, _)| *start);
        out
    }

    fn reference_match(rope: &Rope, target: usize) -> Option<usize> {
        let len = rope.len_chars();
        let start_ch = rope.char(target);
        let (matcher, forward) = match start_ch {
            '{' => ('}', true),
            '[' => (']', true),
            '(' => (')', true),
            '}' => ('{', false),
            ']' => ('[', false),
            ')' => ('(', false),
            _ => return None,
        };
        let mut depth = 1;
        if forward {
            let mut idx = target + 1;
            while idx < len {
                let ch = rope.char(idx);
                if ch == start_ch {
                    depth += 1;
                } else if ch == matcher {
                    depth -= 1;
                    if depth == 0 {
                        return Some(idx);
                    }
                }
                idx += 1;
            }
        } else {
            let mut idx = target;
            while idx > 0 {
                idx -= 1;
                let ch = rope.char(idx);
                if ch == start_ch {
                    depth += 1;
                } else if ch == matcher {
                    depth -= 1;
                    if depth == 0 {
                        return Some(idx);
                    }
                }
            }
        }
        None
    }

    #[test]
    fn the_bracket_scan_matches_the_index_walk_reference() {
        let text = "f(a, [b, {c}, d]) e\n(g)\n[h]\n}\n]\n)\n";
        let rope = Rope::from_str(text);
        let len = rope.len_chars();
        for (idx, ch) in rope.chars().enumerate() {
            if !"()[]{}".contains(ch) {
                continue;
            }
            assert_eq!(
                find_matching_bracket(&rope, idx, len),
                reference_match(&rope, idx),
                "bracket {:?} at {}",
                ch,
                idx
            );
        }
    }

    #[test]
    fn a_pair_past_the_horizon_stays_unmatched() {
        let mut text = String::from("a {\n");
        for _ in 0..60 {
            text.push_str("  b\n");
        }
        text.push_str("}\n");
        let rope = Rope::from_str(&text);
        let close = rope.len_chars() - 2;
        assert_eq!(find_matching_bracket(&rope, 2, close), None);
        assert_eq!(find_matching_bracket(&rope, 2, close + 1), Some(close));
    }

    #[test]
    fn a_horizon_past_the_end_behaves_like_the_documents_end() {
        let rope = Rope::from_str("f(a, b) x { y }");
        let len = rope.len_chars();
        assert_eq!(find_matching_bracket(&rope, 6, usize::MAX), Some(1));
        assert_eq!(find_matching_bracket(&rope, 14, len + 10), Some(10));
    }

    #[test]
    fn a_non_bracket_or_out_of_range_target_has_no_match() {
        let rope = Rope::from_str("f(a, b)");
        let len = rope.len_chars();
        assert_eq!(find_matching_bracket(&rope, 0, len), None);
        assert_eq!(find_matching_bracket(&rope, len, len), None);
        assert_eq!(find_matching_bracket(&rope, len + 5, len), None);
    }

    #[test]
    fn the_single_pass_matches_the_two_pass_reference() {
        let texts = [
            "proxies:\n  - name: a\n    ws-opts:\n      path: /\n\n  - name: b\nrules:\n  - MATCH,DIRECT\n\n",
            "f(a,\n  b:\n    c\n  d)\n",
            "x: {\n  a: 1\n}\n",
            "a {\n  b (\n}\n",
            "f(x, [\n  y)\n]\n",
            "a:\u{feff}\n  b\nc\n",
            "a:\n  b\n\u{feff}\n  c\nd\n",
            "a:\n\tb:\n\t\tc\n",
            "{\n  [\n    (\n    )\n  ]\n}\n",
            "outer:\n  mid:\n    inner:\n      x\n  y\nz:\n  w\n",
            "stray }\nstray ]\nstray )\n",
            "a\n\n\nb:\n\n\n  c\n",
            "",
            "\n",
            "\n\n",
            ":x\n  y\n",
            "  indented\n    more\n",
            "trailing spaces:   \n  body\n",
            "crlf:\r\n  b\r\n\r\nc\r\n",
            "mixed {\r\n  a:\r\n    b\r\n}\r\n",
            "one\ntwo\nthree",
            "colon:\n  a\n  b\n  c:\n    d\n    e\n",
        ];
        for text in texts {
            for tab in [2usize, 4, 0, 1, 8] {
                assert_eq!(
                    compute_all(&Rope::from_str(text), tab)
                        .into_iter()
                        .map(|fold| (fold.start_line, fold.end_line))
                        .collect::<Vec<_>>(),
                    folds_by_two_passes(text, tab),
                    "text={:?} tab={}",
                    text,
                    tab
                );
            }
        }
    }

    #[test]
    fn a_key_folds_over_its_deeper_lines_across_blank_ones() {
        let text = "proxies:\n  - name: a\n    ws-opts:\n      path: /\n\n  - name: b\nrules:\n  - MATCH,DIRECT\n\n";
        assert_eq!(folds(text), [(0, 5), (2, 3), (6, 7)]);
    }

    #[test]
    fn a_key_without_deeper_lines_does_not_fold() {
        assert_eq!(folds("a:\nb: 1\nc:\n"), []);
    }

    #[test]
    fn a_byte_order_mark_counts_as_blank() {
        assert_eq!(folds("a:\u{feff}\n  b\nc\n"), [(0, 1)]);
        assert_eq!(folds("a:\n  b\n\u{feff}\n  c\nd\n"), [(0, 3)]);
    }

    #[test]
    fn a_line_with_both_keeps_the_smaller_fold() {
        assert_eq!(folds("f(a,\n  b:\n    c\n  d)\n"), [(0, 3), (1, 2)]);
        assert_eq!(folds("x: {\n  a: 1\n}\n"), [(0, 2)]);
    }

    #[test]
    fn a_stray_bracket_leaves_the_other_kinds_their_folds() {
        assert_eq!(folds("a {\n  b (\n}\n"), [(0, 2)]);
        assert_eq!(folds("a [\n  b )\n]\n"), [(0, 2)]);
        assert_eq!(folds("f(x, [\n  y)\n]\n"), [(0, 1)]);
    }
}
