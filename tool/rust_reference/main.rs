use code_forge::api::editor::*;
use code_forge::api::rope::*;

fn docs() -> Vec<(&'static str, String)> {
    vec![
        ("empty", "".to_string()),
        ("no_eol", "hello".to_string()),
        ("simple", "a\nb\nc\n".to_string()),
        ("crlf", "line1\r\nline2\r\nline3".to_string()),
        ("blanks", "x\n\n\n  \ny\n".to_string()),
        ("source", "function f(a) {\n  if (a) {\n    return [1, 2,\n      3];\n  }\n\treturn {\n\t\tk: 1\n\t};\n}\n".to_string()),
        ("tags", "<div>\n  <span>\n    hi\n  </span>\n</div>\n<br/>\n".to_string()),
        ("colon", "obj:\n  a: 1\n  b: 2\ntop: 3\n".to_string()),
        ("rtl", "shalom \u{05e9}\u{05dc}\u{05d5}\u{05dd} world \u{0627}\u{0644}\u{0633}\u{0644}\u{0627}\u{0645} done here now".to_string()),
        ("rtlonly", "\u{05e9}\u{05dc}\u{05d5}\u{05dd} \u{05e9}\u{05dc}\u{05d5}\u{05dd} \u{05e9}\u{05dc}\u{05d5}\u{05dd} \u{05e9}\u{05dc}\u{05d5}\u{05dd} \u{05e9}\u{05dc}\u{05d5}\u{05dd} \u{05e9}\u{05dc}\u{05d5}\u{05dd} \u{05e9}\u{05dc}\u{05d5}\u{05dd}".to_string()),
        ("unicode", "caf\u{e9} na\u{ef}ve \u{3053}\u{3093}\u{306b}\u{3061}\u{306f} \u{4e2d}\u{6587}\nsecond \u{3bb}ine\n".to_string()),
    ]
}

fn dir(d: TextDirection) -> &'static str {
    match d { TextDirection::Ltr => "ltr", TextDirection::Rtl => "rtl", TextDirection::Mixed => "mixed" }
}

fn main() {
    for (name, text) in docs() {
        let r = RopeBridge::create(text.clone());
        println!("## doc {}", name);
        println!("lenChars {}", r.len_chars());
        println!("lenLines {}", r.len_lines());
        println!("getText {:?}", r.get_text());
        println!("primaryDirection {}", dir(r.primary_direction()));
        println!("textDirection {}", dir(r.text_direction()));

        let n = r.len_chars();
        for i in 0..=n {
            println!("charToLine {} {}", i, r.char_to_line(i));
            println!("findLineStart {} {}", i, r.find_line_start(i));
            println!("findLineEnd {} {}", i, r.find_line_end(i));
            println!("charAt {} {:?}", i, r.char_at(i));
        }
        for l in 0..r.len_lines() + 1 {
            println!("line {} {:?}", l, r.line(l));
            println!("lineToChar {} {}", l, r.line_to_char(l));
            let segs = r.get_bidi_segments_for_line(l);
            println!("bidiLine {} {}", l, segs.iter()
                .map(|s| format!("{}-{}:{}", s.start, s.end, dir(s.direction)))
                .collect::<Vec<_>>().join(","));
        }
        for a in 0..=n {
            for b in 0..=n {
                if (a + b) % 3 == 0 {
                    println!("slice {} {} {:?}", a, b, r.slice(a, b));
                }
            }
        }
        println!("cachedLines {:?}", r.cached_lines());
        for a in 0..=r.len_lines() {
            for b in 0..=r.len_lines() {
                println!("cachedLinesRange {} {} {:?}", a, b, r.cached_lines_range(a, b));
            }
        }
        for a in 0..=n {
            for b in 0..=n {
                if (a * 7 + b) % 5 == 0 {
                    println!("bidiRange {} {} {}", a, b, r.get_bidi_segments_in_range(a, b)
                        .iter().map(|s| format!("{}-{}:{}", s.start, s.end, dir(s.direction)))
                        .collect::<Vec<_>>().join(","));
                }
            }
        }

        // mutation semantics
        for start in 0..=n.min(12) {
            for end in start..=n.min(12) {
                for (pres, repl) in [(true, ""), (false, ""), (true, "XY"), (false, "XY"), (true, "\n")] {
                    let c = r.copy();
                    let s = c.replace_range_and_update_selection(
                        start, end, repl.to_string(), pres, 2.min(n), 5.min(n));
                    println!("replace {} {} {:?} {} -> {} {} {:?}",
                        start, end, repl, pres, s.base_offset, s.extent_offset, c.get_text());
                }
            }
        }

        // free functions
        let folds = folds_compute_all(&r);
        println!("folds {}", folds.iter().map(|f| format!("{}-{}", f.start_line, f.end_line))
            .collect::<Vec<_>>().join(","));
        for i in 0..n {
            let m = folds_find_matching_bracket(&r, i as i32);
            if m != -1 { println!("bracket {} {}", i, m); }
        }
        let mut words = words_extract(&r);
        words.sort();
        println!("words {:?}", words);
        for tab in [0usize, 2, 4, 8] {
            for last in 0..=r.len_lines() {
                let g = guides_compute_viewport(&r, 0, last, tab);
                println!("guides {} {} {}", tab, last, g.iter()
                    .map(|b| format!("{}-{}:{}:{}", b.start_line, b.end_line, b.indent_level, b.leading_spaces))
                    .collect::<Vec<_>>().join(","));
            }
        }
        for (vt, vb, lh) in [(0.0, 100.0, 20.0), (35.0, 90.0, 20.0), (0.0, 0.0, 0.0), (-10.0, 5.0, 18.0), (1000.0, 2000.0, 18.0)] {
            let v = visible_line_range_unwrapped(r.len_lines() as i32, vt, vb, lh);
            println!("vlru {} {} {} -> {} {} {:.4}", vt, vb, lh, v.first_line, v.last_line, v.first_line_y);
            let f = build_viewport_frame(&r, vt, vb, lh);
            println!("bvf {} {} {} -> {} {} {:.4} [{}]", vt, vb, lh, f.first_line, f.last_line, f.first_line_y,
                f.lines.iter().map(|l| format!("{}:{:.4}", l.len_chars, l.height)).collect::<Vec<_>>().join(","));
        }
    }

    // LayoutMap: deterministic op script
    println!("## layoutmap");
    let mut lm = LayoutMap::new();
    let mut seed: u64 = 12345;
    let mut next = |m: usize| { seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407); ((seed >> 33) as usize) % m.max(1) };
    for step in 0..300 {
        let op = next(10);
        let idx = next(40);
        let len = next(80);
        let h = (next(30) as f32) + 0.5;
        let folded = next(4) == 0;
        match op {
            0..=4 => lm.push_line(len, h, folded),
            5..=6 => lm.insert_line(idx, len, h, folded),
            7 => lm.remove_line(idx),
            8 => lm.update_line(idx, len, h, folded),
            _ => {}
        }
        if step % 10 == 0 {
            println!("lm {} lines {} height {:.4}", step, lm.len_lines(), lm.total_height());
            for co in [0usize, 1, 17, 100, 999, 100000] {
                println!("lm {} vlfco {} {}", step, co, lm.visual_line_from_char_offset(co));
            }
            for (vt, vb) in [(0.0, 50.0), (10.0, 10.0), (100.0, 300.0), (-5.0, 3.0), (99999.0, 100000.0)] {
                let v = lm.visible_range_by_height(vt, vb);
                println!("lm {} vrbh {} {} -> {} {} {:.4}", step, vt, vb, v.first_line, v.last_line, v.first_line_y);
                let f = lm.build_viewport_frame(vt, vb, 17.0);
                println!("lm {} lbvf {} {} -> {} {} {:.4} [{}]", step, vt, vb, f.first_line, f.last_line, f.first_line_y,
                    f.lines.iter().map(|l| format!("{}:{:.4}", l.len_chars, l.height)).collect::<Vec<_>>().join(","));
            }
        }
    }
    lm.clear();
    println!("lm cleared lines {} height {:.4}", lm.len_lines(), lm.total_height());
}

