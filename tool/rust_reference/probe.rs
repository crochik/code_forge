use code_forge::api::editor::LayoutMap;

/// Dump the block list by asking for a viewport that covers everything.
fn dump(lm: &LayoutMap) -> String {
    let f = lm.build_viewport_frame(0.0, 1e9, 17.0);
    f.lines.iter().map(|l| l.len_chars.to_string()).collect::<Vec<_>>().join(",")
}

fn fresh(n: usize) -> LayoutMap {
    let mut lm = LayoutMap::new();
    for i in 0..n { lm.push_line(i, 10.0, false); }
    lm
}

fn main() {
    println!("base(5) = {}", dump(&fresh(5)));
    for k in 0..7 {
        let mut lm = fresh(5);
        lm.insert_line(k, 99, 10.0, false);
        println!("insert_line({}) -> {}", k, dump(&lm));
    }
    for k in 0..7 {
        let mut lm = fresh(5);
        lm.remove_line(k);
        println!("remove_line({}) -> {}", k, dump(&lm));
    }
    for k in 0..7 {
        let mut lm = fresh(5);
        lm.update_line(k, 77, 10.0, false);
        println!("update_line({}) -> {}", k, dump(&lm));
    }
    // char-offset seek: blocks are 0,1,2,3,4 chars => prefix 0,0,1,3,6,10
    let lm = fresh(5);
    for co in 0..13 {
        println!("vlfco({}) = {}", co, lm.visual_line_from_char_offset(co));
    }
    // height seek with uniform 10.0
    for t in [0.0, 5.0, 10.0, 15.0, 20.0, 49.0, 50.0, 51.0] {
        let v = lm.visible_range_by_height(t, t);
        println!("vrbh({},{}) = {} {} {}", t, t, v.first_line, v.last_line, v.first_line_y);
    }
    // folded lines produce zero-height runs: where left/right bias diverge
    let mut lm2 = LayoutMap::new();
    lm2.push_line(0, 10.0, false);
    lm2.push_line(1, 10.0, true);   // folded -> 0 height
    lm2.push_line(2, 10.0, true);   // folded -> 0 height
    lm2.push_line(3, 10.0, false);
    println!("folded dump = {}", dump(&lm2));
    println!("folded total = {}", lm2.total_height());
    for t in [0.0, 5.0, 10.0, 15.0, 20.0] {
        let v = lm2.visible_range_by_height(t, t);
        println!("folded vrbh({}) = {} {} {}", t, v.first_line, v.last_line, v.first_line_y);
    }
}
