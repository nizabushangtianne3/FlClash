use ropey::Rope;
use std::collections::HashSet;

const MAX_WORDS: usize = 5_000;

// Mirrors plugins/code_forge/lib/code_forge/word_chars.dart; its first three
// ranges are the ASCII ones inlined into is_word_char.
const WORD_RANGES: [(char, char); 10] = [
    ('\u{61}', '\u{7A}'),
    ('\u{0590}', '\u{05FF}'),
    ('\u{0600}', '\u{06FF}'),
    ('\u{08A0}', '\u{08FF}'),
    ('\u{3040}', '\u{309F}'),
    ('\u{30A0}', '\u{30FF}'),
    ('\u{3400}', '\u{4DBF}'),
    ('\u{4E00}', '\u{9FFF}'),
    ('\u{AC00}', '\u{D7AF}'),
    ('\u{F900}', '\u{FAFF}'),
];

fn is_word_char(ch: char) -> bool {
    match ch {
        '0'..='9' | 'A'..='Z' | '_' | 'a'..='z' => true,
        _ => {
            !ch.is_ascii()
                && WORD_RANGES
                    .iter()
                    .any(|&(from, to)| (from..=to).contains(&ch))
        }
    }
}

pub fn extract(rope: &Rope) -> Vec<String> {
    let mut word = String::new();
    collect_words(rope, &mut word).into_iter().collect()
}

fn collect_words(rope: &Rope, word: &mut String) -> HashSet<String> {
    let mut words = HashSet::new();
    let mut flush = |word: &mut String| {
        let starts_word = word.chars().next().is_some_and(|c| !c.is_ascii_digit());
        if starts_word && words.len() < MAX_WORDS {
            words.insert(word.clone());
            // Clearing keeps the capacity; taking would regrow it per word.
            word.clear();
        } else {
            word.clear();
        }
    };
    for ch in rope.chars() {
        if is_word_char(ch) {
            word.push(ch);
        } else if !word.is_empty() {
            flush(word);
        }
    }
    flush(word);
    words
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sorted(text: &str) -> Vec<String> {
        let mut words = extract(&Rope::from_str(text));
        words.sort();
        words
    }

    #[test]
    fn words_follow_the_dart_word_chars() {
        assert_eq!(
            sorted("a1 1abc _x café 名前 8080"),
            ["_x", "a1", "caf", "名前"]
        );
    }

    #[test]
    fn the_whole_range_set_matches_the_dart_ranges() {
        let boundaries = [
            ('\u{2F}', false),
            ('\u{30}', true),
            ('\u{39}', true),
            ('\u{3A}', false),
            ('\u{40}', false),
            ('\u{41}', true),
            ('\u{5A}', true),
            ('\u{5B}', false),
            ('\u{5E}', false),
            ('\u{5F}', true),
            ('\u{60}', false),
            ('\u{61}', true),
            ('\u{7A}', true),
            ('\u{7B}', false),
            ('\u{058F}', false),
            ('\u{0590}', true),
            ('\u{05FF}', true),
            ('\u{0600}', true),
            ('\u{06FF}', true),
            ('\u{0700}', false),
            ('\u{089F}', false),
            ('\u{08A0}', true),
            ('\u{08FF}', true),
            ('\u{0900}', false),
            ('\u{303F}', false),
            ('\u{3040}', true),
            ('\u{309F}', true),
            ('\u{30A0}', true),
            ('\u{30FF}', true),
            ('\u{3100}', false),
            ('\u{33FF}', false),
            ('\u{3400}', true),
            ('\u{4DBF}', true),
            ('\u{4DC0}', false),
            ('\u{4DFF}', false),
            ('\u{4E00}', true),
            ('\u{9FFF}', true),
            ('\u{A000}', false),
            ('\u{ABFF}', false),
            ('\u{AC00}', true),
            ('\u{D7AF}', true),
            ('\u{D7B0}', false),
            ('\u{F8FF}', false),
            ('\u{F900}', true),
            ('\u{FAFF}', true),
            ('\u{FB00}', false),
        ];
        for (ch, expected) in boundaries {
            assert_eq!(is_word_char(ch), expected, "U+{:04X}", ch as u32);
        }
    }

    #[test]
    fn the_word_buffer_keeps_its_capacity() {
        let text = "aaaaaaaaaaaaaaaaaaaaa b c d e f g h i j k l m n o p q r s t u";
        let mut buffer = String::new();

        let words = collect_words(&Rope::from_str(text), &mut buffer);
        assert_eq!(words.len(), 21);
        let grown = buffer.capacity();
        assert!(grown >= 20, "capacity {}", grown);

        let again = collect_words(&Rope::from_str(text), &mut buffer);
        assert_eq!(again.len(), 21);
        assert_eq!(buffer.capacity(), grown);
    }
}
