const std = @import("std");

const log = std.log.scoped(.rbtree);

//

pub const RedBlackTree = struct {
    root: ?*Node = null,
    // /// cached first node
    // first: ?*Node = null,
    // /// cached last node
    // last: ?*Node = null,
    size: usize = 0,

    const Color = enum(u1) {
        black,
        red,
    };

    const Side = enum(u1) {
        left,
        right,

        fn flip(self: @This()) @This() {
            return @enumFromInt(1 - @intFromEnum(self));
        }
    };

    const ColorSideAndParent = packed struct {
        color: Color = .black,
        side: Side = .left,
        ptr: u62 = 0,
    };

    pub const Node = struct {
        left: ?*Node = null,
        right: ?*Node = null,
        // parent pointerless rb-trees
        // can't have simple+efficient iterators
        // and the memory saving is't very great
        extra: ColorSideAndParent = .{},

        comptime {
            std.debug.assert(@alignOf(Node) != 1);
        }

        fn setChild(self: *@This(), side: Side, node: ?*Node) void {
            if (side == .left) self.left = node else self.right = node;
        }

        fn setParent(self: *@This(), new: ?*Node) void {
            std.debug.assert(@as(u3, @truncate(@intFromPtr(new))) == 0);
            self.extra.ptr = @truncate(@intFromPtr(new) >> 1);
        }

        fn childPtr(self: *@This(), side: Side) *?*Node {
            const result = if (side == .left) &self.left else &self.right;
            std.debug.assert(result.* == null or result.*.?.extra.side == side);
            return result;
        }

        fn child(self: *@This(), side: Side) ?*Node {
            return self.childPtr(side).*;
        }

        fn parent(self: @This()) ?*Node {
            std.debug.assert(@as(u2, @truncate(self.extra.ptr)) == 0);
            return @ptrFromInt(@as(u64, self.extra.ptr) << 1);
        }

        fn resetSide(self: *@This()) void {
            if (self.extra.ptr == 0) return;
            self.extra.side = sideOf(self);
        }

        // fn grandparent(self: @This()) ?*Node {
        //     const par = self.parent() orelse return null;
        //     return par.parent();
        // }

        // fn uncle(self: @This()) ?*Node {

        // }

        // fn sibling(self: @This()) ?*Node {
        //     const par = self.parent() orelse return null;
        //     return par.child(self.extra.side.flip());
        // }
    };

    pub const Entry = struct {
        parent: ?*Node,
        this: *?*Node,
        depth: u6 = 0,
    };

    /// O(log n) insert `node` into the tree using `comparator` to compare nodes,
    /// returning the old node if there was a conflict
    pub fn put(
        self: *@This(),
        comparator: *const fn (*const Node, *const Node) std.math.Order,
        node: *Node,
    ) ?*Node {
        const entry = self.getEntry(comparator, node);
        return self.putEntry(entry, node);
    }

    /// O(log n) remove the real node using a dummy node
    pub fn findRemove(
        self: *@This(),
        comparator: *const fn (*const Node, *const Node) std.math.Order,
        node: *const Node,
    ) ?*Node {
        const entry = self.getEntry(comparator, node);
        return self.removeEntry(entry);
    }

    /// O(1) remove a node from the tree directly
    pub fn remove(
        self: *@This(),
        node: *Node,
    ) void {
        const parent = node.parent().?;
        const this = if (parent.left == node)
            &parent.left
        else
            &parent.right;
        const old = self.removeEntry(.{
            .parent = parent,
            .this = this,
        });
        std.debug.assert(old == node);
    }

    /// O(log n) look up the real node using a dummy node
    pub fn get(
        self: *@This(),
        comparator: *const fn (*const Node, *const Node) std.math.Order,
        node: *const Node,
    ) ?*Node {
        return self.getEntry(comparator, node).this.*;
    }

    /// O(1) insert, requires knowing the entry
    pub fn putEntry(
        self: *@This(),
        entry: Entry,
        node: *Node,
    ) ?*Node {
        if (takeAndReplace(entry.this, node)) |old| {
            // case 0 (old entry replaced)
            // std.debug.print("insert simple case 0\n", .{});
            node.* = old.*;
            old.* = undefined;
            if (node.left) |left| left.setParent(node);
            if (node.right) |right| right.setParent(node);
            return old;
        }

        node.left = null;
        node.right = null;
        node.extra.color = .red;
        node.setParent(entry.parent);
        node.resetSide();
        self.size += 1;
        self.rebalanceAfterPut(node);

        return null;
    }

    /// O(1) remove, requires knowing the entry
    pub fn removeEntry(
        self: *@This(),
        /// pointer to a node pointer stored in a parent node or root
        old_entry: Entry,
    ) ?*Node {
        defer self.verify(TestNode.cmp);

        if (old_entry.this.* == null) {
            // case 0 (old entry null)
            // std.debug.print("insert simple case 0\n", .{});
            return null;
        }

        self.size -= 1;
        var node = old_entry.this.*.?;
        var node_entry = self.entryOf(node.*);

        while (true) {
            std.debug.assert(node_entry.*.? == node);
            // std.debug.print("remove simple start (node=", .{});
            // TestNode.print(node);
            // std.debug.print(")\n", .{});

            // simple cases

            if (node.left != null and node.right != null) {
                // std.debug.print("remove simple case 1\n", .{});
                const successor_entry = leftmost(&node.right).this;
                const successor = successor_entry.*.?;
                std.debug.assert(successor.left == null);
                std.debug.assert(successor != node);
                std.mem.swap(?*Node, successor_entry, node_entry);
                std.mem.swap(Node, successor, node);
                node = successor;
                node_entry = node_entry;
                continue;
            }

            if (node.left) |left| {
                // std.debug.print("remove simple case 2a\n", .{});
                std.debug.assert(node.extra.color == .black);
                std.debug.assert(left.extra.color == .red);
                node_entry.* = left;
                left.extra.color = .black;
                left.setParent(node.parent());
                left.resetSide();
                break;
            }

            if (node.right) |right| {
                // std.debug.print("remove simple case 2b\n", .{});
                std.debug.assert(node.extra.color == .black);
                std.debug.assert(right.extra.color == .red);
                node_entry.* = right;
                right.extra.color = .black;
                right.setParent(node.parent());
                right.resetSide();
                break;
            }

            if (node.parent() == null) {
                // std.debug.print("remove simple case 3\n", .{});
                self.root = null;
                break;
            }

            if (node.extra.color == .red) {
                // std.debug.print("remove simple case 4\n", .{});
                node_entry.* = null;
                break;
            }

            if (node.extra.color == .black) {
                node_entry.* = null;
                self.rebalanceAfterRemove(node);
                break;
            }
        }

        node.* = undefined;
        return node;
    }

    fn takeAndReplace(dst: *?*Node, new: ?*Node) ?*Node {
        var tmp = new;
        std.mem.swap(?*Node, dst, &tmp);
        return tmp;
    }

    fn rebalanceAfterPut(
        self: *@This(),
        node_: *Node,
    ) void {
        // std.debug.print("rebalance (k=", .{});
        // TestNode.print(node_);
        // std.debug.print(")\n", .{});
        // defer self.verify(TestNode.cmp);
        // defer {
        //     std.debug.print("completed insert rebalance\n", .{});
        //     self.debug(TestNode.print);
        // }

        var node = node_;
        var parent = node.parent() orelse {
            return;
        };
        var dir: Side = undefined;
        var grandparent: *Node = undefined;
        var uncle: ?*Node = undefined;

        const State = enum {
            start,
            case_1,
            case_2,
            case_3,
            case_4,
            case_5,
            case_6,
        };

        loop: switch (State.start) {
            .start => {
                // std.debug.print("insert rebalance start (node=", .{});
                // TestNode.print(node);
                // std.debug.print(")\n", .{});
                // self.debug(TestNode.print);
                std.debug.assert(node.extra.color == .red);

                if (parent.extra.color == .black) {
                    continue :loop .case_1;
                }

                grandparent = parent.parent() orelse {
                    continue :loop .case_4;
                };

                dir = parent.extra.side;
                uncle = grandparent.child(dir.flip());
                std.debug.assert(uncle != parent);

                if (uncle == null or uncle.?.extra.color == .black) {
                    if (node == parent.child(dir.flip())) {
                        continue :loop .case_5;
                    }

                    continue :loop .case_6;
                }

                continue :loop .case_2;
            },
            .case_1 => {
                // std.debug.print("insert rebalance case 1\n", .{});
                // self.debug(TestNode.print);
                return;
            },
            .case_2 => {
                // std.debug.print("insert rebalance case 2\n", .{});
                // self.debug(TestNode.print);
                parent.extra.color = .black;
                uncle.?.extra.color = .black;
                grandparent.extra.color = .red;
                node = grandparent;
                // std.debug.print("case 2\n", .{});
                // self.debug(TestNode.print);
                parent = node.parent() orelse {
                    continue :loop .case_3;
                };
                continue :loop .start;
            },
            .case_3 => {
                // std.debug.print("insert rebalance case 3\n", .{});
                // self.debug(TestNode.print);
                return;
            },
            .case_4 => {
                // std.debug.print("insert rebalance case 4\n", .{});
                // self.debug(TestNode.print);
                parent.extra.color = .black;
                return;
            },
            .case_5 => {
                // std.debug.print("insert rebalance case 5\n", .{});
                // self.debug(TestNode.print);
                _ = self.rotate_node(parent, dir);
                node = parent;
                parent = grandparent.child(dir).?;
                continue :loop .case_6;
            },
            .case_6 => {
                // std.debug.print("insert rebalance case 6\n", .{});
                // self.debug(TestNode.print);
                _ = self.rotate_node(grandparent, dir.flip());
                parent.extra.color = .black;
                grandparent.extra.color = .red;
                return;
            },
        }
    }

    fn rebalanceAfterRemove(
        self: *@This(),
        node_: *Node,
    ) void {
        // self.debug(TestNode.print);
        // defer self.verify(TestNode.cmp);
        // defer {
        //     std.debug.print("completed remove rebalance\n", .{});
        //     self.debug(TestNode.print);
        // }

        var node = node_;
        var parent = node.parent().?;
        var side = node.extra.side;

        const State = enum {
            start,
            case_1,
            case_2,
            case_3,
            case_4,
            case_5,
            case_6,
        };

        var sibling: *Node = undefined;
        var distant_nephew: ?*Node = undefined;
        var close_nephew: ?*Node = undefined;

        loop: switch (State.start) {
            .start => {
                // std.debug.print("remove rebalance start (node=", .{});
                // TestNode.print(node);
                // std.debug.print(")\n", .{});

                sibling = parent.child(side.flip()).?;
                distant_nephew = sibling.child(side.flip());
                close_nephew = sibling.child(side);

                if (sibling.extra.color == .red) {
                    continue :loop .case_3;
                }

                if (distant_nephew != null and
                    distant_nephew.?.extra.color == .red)
                {
                    continue :loop .case_6;
                }
                if (close_nephew != null and
                    close_nephew.?.extra.color == .red)
                {
                    continue :loop .case_5;
                }

                // // ??? how can the parent be null randomly
                // if (parent == null) {
                //     continue :loop .case_1;
                // }

                if (parent.extra.color == .red) {
                    continue :loop .case_4;
                }

                continue :loop .case_2;
            },
            .case_1 => {
                // std.debug.print("remove rebalance case 1\n", .{});
                return;
            },
            .case_2 => {
                // std.debug.print("remove rebalance case 2\n", .{});
                sibling.extra.color = .red;
                node = parent;
                parent = node.parent().?;
                side = node.extra.side;
                continue :loop .start;
            },
            .case_3 => {
                // std.debug.print("remove rebalance case 3\n", .{});
                _ = self.rotate_node(parent, side);
                parent.extra.color = .red;
                sibling.extra.color = .black;
                sibling = close_nephew.?;

                distant_nephew = sibling.child(side.flip());
                if (distant_nephew != null and
                    distant_nephew.?.extra.color == .red)
                {
                    continue :loop .case_6;
                }
                close_nephew = sibling.child(side);
                if (close_nephew != null and
                    close_nephew.?.extra.color == .red)
                {
                    continue :loop .case_5;
                }

                continue :loop .case_4;
            },
            .case_4 => {
                // std.debug.print("remove rebalance case 4\n", .{});
                sibling.extra.color = .red;
                parent.extra.color = .black;
                return;
            },
            .case_5 => {
                // std.debug.print("remove rebalance case 5 (side={any})\n", .{side.flip()});
                _ = self.rotate_node(sibling, side.flip());
                sibling.extra.color = .red;
                close_nephew.?.extra.color = .black;
                distant_nephew = sibling;
                sibling = close_nephew.?;
                continue :loop .case_6;
            },
            .case_6 => {
                // std.debug.print("remove rebalance case 6 (side={any})\n", .{side});
                // std.debug.print("n={} p={} gp={?} s={} dn={?} cn={?}\n", .{
                //     TestNode.of(node).key,
                //     TestNode.of(parent).key,
                //     TestNode.keyOpt(parent.parent()),
                //     TestNode.of(sibling).key,
                //     TestNode.keyOpt(distant_nephew),
                //     TestNode.keyOpt(close_nephew),
                // });
                _ = self.rotate_node(parent, side);
                sibling.extra.color = parent.extra.color;
                parent.extra.color = .black;
                distant_nephew.?.extra.color = .black;
                return;
            },
        }
    }

    /// O(log n) lookup
    pub fn getEntry(
        self: *@This(),
        comparator: *const fn (*const Node, *const Node) std.math.Order,
        node: *const Node,
    ) Entry {
        var entry: Entry = .{
            .parent = null,
            .this = &self.root,
        };
        while (entry.this.*) |cur| {
            const next = switch (comparator(node, cur)) {
                .gt => &cur.right,
                .lt => &cur.left,
                .eq => break,
            };
            entry.parent = cur;
            entry.this = next;
            entry.depth += 1;
        }
        return entry;
    }

    /// O(log n) lookup
    pub fn firstEntry(
        self: *@This(),
    ) Entry {
        return leftmost(&self.root);
    }

    /// get a pointer to the pointer that points to this node
    fn entryOf(self: *@This(), node: Node) *?*Node {
        const parent = node.parent() orelse {
            return &self.root;
        };
        return parent.childPtr(node.extra.side);
    }

    fn leftmost(
        subtree: *?*Node,
    ) Entry {
        var entry: Entry = .{
            .parent = null,
            .this = subtree,
        };
        while (entry.this.*) |cur| {
            if (cur.left == null) break;
            entry.parent = cur;
            entry.this = &cur.left;
            entry.depth += 1;
        }
        return entry;
    }

    fn rightmost(
        subtree: *?*Node,
    ) Entry {
        var entry: Entry = .{
            .parent = null,
            .this = subtree,
        };
        while (entry.this.*) |cur| {
            if (cur.right == null) break;
            entry.parent = cur;
            entry.this = &cur.right;
            entry.depth += 1;
        }
        return entry;
    }

    fn sideOf(
        node: *const Node,
    ) Side {
        if (node.parent().?.left == node) {
            return .left;
        } else {
            return .right;
        }
    }

    fn rotate_node(self: *@This(), node: *Node, side: Side) *Node {
        const subtree_parent = node.parent();
        const new_subtree_root = node.child(side.flip()).?;

        const new_child = new_subtree_root.child(side);
        node.setChild(side.flip(), new_child);
        if (new_child) |new_child_| {
            new_child_.setParent(node);
            new_child_.resetSide();
        }

        new_subtree_root.setChild(side, node);
        new_subtree_root.setParent(subtree_parent);
        node.setParent(new_subtree_root);
        if (subtree_parent) |subtree_parent_| {
            const subtree_dir = if (subtree_parent_.left == node)
                Side.left
            else
                Side.right;
            subtree_parent_.setChild(subtree_dir, new_subtree_root);
        } else {
            self.root = new_subtree_root;
        }

        new_subtree_root.resetSide();
        node.resetSide();
        return new_subtree_root;
    }

    pub const Iterator = struct {
        node: ?*Node,
        right_turn_bitfield: usize,
        depth: u6,

        pub fn next(
            self: *@This(),
        ) ?*Node {
            const cur = self.node orelse return null;

            if (cur.right) |right| {
                self.right_turn_bitfield |= @as(usize, 1) << self.depth;
                self.depth += 1;

                var successor = right;
                while (successor.left) |left| {
                    self.right_turn_bitfield &= ~(@as(usize, 1) << self.depth);
                    self.depth += 1;
                    successor = left;
                }
                self.node = successor;
            } else {
                // go back up as long as the current node
                // is on the right side of the subtree
                while (true) {
                    self.depth -|= 1;
                    const was_right_turn = (self.right_turn_bitfield & (@as(usize, 1) << self.depth)) != 0;
                    self.right_turn_bitfield &= ~(@as(usize, 1) << self.depth);
                    self.node = self.node.?.parent();

                    if (!was_right_turn) break;
                }
            }

            return cur;
        }
    };

    pub fn iterator(
        self: *const @This(),
    ) Iterator {
        const entry = @constCast(self).firstEntry();
        return .{
            .node = entry.this.*,
            .right_turn_bitfield = 0,
            .depth = entry.depth,
        };
    }

    pub fn debug(
        self: *const @This(),
        print: *const fn (*const Node) void,
    ) void {
        var prefix = Rope{};
        self.debugRecurse(self.root, print, &prefix, false);
    }

    fn debugRecurse(
        self: *const @This(),
        node_: ?*const Node,
        print: *const fn (*const Node) void,
        prefix: *Rope,
        is_left: bool,
    ) void {
        std.debug.print("\x1b[90m", .{});
        prefix.print();

        const hori =
            if (is_left) "├────" else "└────";
        std.debug.print("{s}", .{hori});

        const node = node_ orelse {
            std.debug.print("\x1b[30mNIL\x1b[0m\n", .{});
            return;
        };

        std.debug.print("{s}", .{if (node.extra.color == .red) "\x1b[31m" else "\x1b[30m"});
        print(node);
        std.debug.print("{s}\x1b[0m\n", .{
            if (node == self.root or (node.extra.side == .left) == is_left) "" else " !",
        });

        var vert =
            prefix.push(if (is_left) "│    " else "     ");
        self.debugRecurse(node.left, print, &vert, true);
        self.debugRecurse(node.right, print, &vert, false);
    }

    const Rope = struct {
        prev: ?*@This() = null,
        next: ?*@This() = null,
        this: []const u8 = "",

        fn print(self: *@This()) void {
            // construct next chain
            var cur = self;
            cur.next = null;
            while (cur.prev) |prev| {
                prev.next = cur;
                cur = prev;
            }
            // print using the next chain
            while (cur.next) |next| {
                std.debug.print("{s}", .{cur.this});
                cur = next;
            }
            std.debug.print("{s}", .{cur.this});
            // // print in reverse
            // var cur = self;
            // while (cur.prev) |next| {
            //     std.debug.print("{s}", .{cur.this});
            //     cur = next;
            // }
        }

        fn push(self: *@This(), part: []const u8) Rope {
            return .{
                .prev = self,
                .this = part,
            };
        }
    };

    pub fn verify(
        self: *const @This(),
        comparator: *const fn (*const Node, *const Node) std.math.Order,
    ) void {
        var black_height: ?usize = null;
        var node_count: usize = 0;
        if (self.root) |root| {
            std.debug.assert(root.extra.ptr == 0);
        }
        verifyRecurse(
            comparator,
            self.root,
            0,
            &black_height,
            &node_count,
        );
        std.debug.assert(node_count == self.size);
    }

    fn verifyRecurse(
        comparator: *const fn (*const Node, *const Node) std.math.Order,
        _cur: ?*const Node,
        black_depth: usize,
        black_height: *?usize,
        node_count: *usize,
    ) void {
        if (_cur) |cur| {
            node_count.* += 1;

            if (cur.left) |left| {
                std.debug.assert(comparator(left, cur) == .lt);
                std.debug.assert(left.parent() == cur);
                std.debug.assert(cur.extra.color == .black or left.extra.color == .black);
                std.debug.assert(left.extra.side == .left);
            }
            if (cur.right) |right| {
                std.debug.assert(comparator(cur, right) == .lt);
                std.debug.assert(right.parent() == cur);
                std.debug.assert(cur.extra.color == .black or right.extra.color == .black);
                std.debug.assert(right.extra.side == .right);
            }

            const next_black_depth = black_depth + @intFromBool(cur.extra.color == .black);
            verifyRecurse(
                comparator,
                cur.left,
                next_black_depth,
                black_height,
                node_count,
            );
            verifyRecurse(
                comparator,
                cur.right,
                next_black_depth,
                black_height,
                node_count,
            );
        } else if (black_height.*) |known_black_depth| {
            // black height of every leaf node has to be the same
            std.debug.assert(known_black_depth == black_depth + 1);
        } else {
            black_height.* = black_depth + 1;
        }
    }
};

// test cases stolen from Rust's BTreeMap doctests

const TestNode = struct {
    key: u8,
    value: u8 = undefined,
    node: RedBlackTree.Node = .{},

    fn keyOpt(node: ?*const RedBlackTree.Node) ?u8 {
        return (ofOpt(node) orelse return null).key;
    }

    fn valueOpt(node: ?*const RedBlackTree.Node) ?u8 {
        return (ofOpt(node) orelse return null).value;
    }

    fn ofOpt(node: ?*const RedBlackTree.Node) ?*const @This() {
        return @fieldParentPtr("node", node orelse return null);
    }

    fn of(node: *const RedBlackTree.Node) *const @This() {
        return @fieldParentPtr("node", node);
    }

    fn cmp(lhs_node: *const RedBlackTree.Node, rhs_node: *const RedBlackTree.Node) std.math.Order {
        return std.math.order(of(lhs_node).key, of(rhs_node).key);
    }

    pub fn format(self: *const @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return writer.print(".{{ .key = {}, .value = {} }}", .{
            self.key, self.value,
        });
    }

    fn print(node: *const RedBlackTree.Node) void {
        std.debug.print("{d}", .{of(node).key});
    }
};

test "node size/align" {
    try std.testing.expectEqual(@sizeOf(RedBlackTree.Node), @sizeOf(usize) * 3);
    try std.testing.expectEqual(@alignOf(RedBlackTree.Node), @sizeOf(usize));
}

test "insert" {
    var map: RedBlackTree = .{};
    var node_a: TestNode = .{ .key = 1, .value = 'a' };
    var node_b: TestNode = .{ .key = 1, .value = 'b' };

    map.verify(TestNode.cmp);
    try std.testing.expectEqual(0, map.size);

    var old = map.put(TestNode.cmp, &node_a.node);
    try std.testing.expectEqual(null, old);

    map.verify(TestNode.cmp);
    try std.testing.expectEqual(1, map.size);

    old = map.put(TestNode.cmp, &node_b.node);
    try std.testing.expectEqual(&node_a.node, old);

    map.verify(TestNode.cmp);
    try std.testing.expectEqual(1, map.size);
}

test "remove" {
    var map: RedBlackTree = .{};
    // inserted node
    var node_a: TestNode = .{ .key = 1, .value = 'a' };
    // dummy node for access
    var node_b: TestNode = .{ .key = 1, .value = 'b' };

    map.verify(TestNode.cmp);
    try std.testing.expectEqual(0, map.size);

    const old = map.put(TestNode.cmp, &node_a.node);
    try std.testing.expectEqual(null, old);

    map.verify(TestNode.cmp);
    try std.testing.expectEqual(1, map.size);

    var removed = map.findRemove(TestNode.cmp, &node_b.node);
    try std.testing.expectEqual(&node_a.node, removed);

    map.verify(TestNode.cmp);
    try std.testing.expectEqual(0, map.size);

    removed = map.findRemove(TestNode.cmp, &node_b.node);
    try std.testing.expectEqual(null, removed);

    map.verify(TestNode.cmp);
    try std.testing.expectEqual(0, map.size);
}

test "get" {
    var map: RedBlackTree = .{};
    // inserted node
    var node_a: TestNode = .{ .key = 1, .value = 'a' };
    // dummy nodes for access
    var node_b: TestNode = .{ .key = 1, .value = 'a' };
    var node_c: TestNode = .{ .key = 2, .value = 'b' };

    const old = map.put(TestNode.cmp, &node_a.node);
    try std.testing.expectEqual(null, old);

    var found = map.get(TestNode.cmp, &node_b.node);
    try std.testing.expectEqual(&node_a.node, found);
    found = map.get(TestNode.cmp, &node_c.node);
    try std.testing.expectEqual(null, found);
}

test "iterator" {
    var map: RedBlackTree = .{};
    var node_a: TestNode = .{ .key = 1, .value = 'a' };
    var node_b: TestNode = .{ .key = 2, .value = 'b' };
    var node_c: TestNode = .{ .key = 3, .value = 'c' };
    var node_d: TestNode = .{ .key = 4, .value = 'd' };

    // insert out of order
    const a = map.put(TestNode.cmp, &node_d.node);
    try std.testing.expectEqual(null, a);
    const b = map.put(TestNode.cmp, &node_b.node);
    try std.testing.expectEqual(null, b);
    const c = map.put(TestNode.cmp, &node_a.node);
    try std.testing.expectEqual(null, c);
    const d = map.put(TestNode.cmp, &node_c.node);
    try std.testing.expectEqual(null, d);

    // iterate in order
    var iter = map.iterator();
    try std.testing.expectEqual(1, TestNode.ofOpt(iter.next()).?.key);
    try std.testing.expectEqual(2, TestNode.ofOpt(iter.next()).?.key);
    try std.testing.expectEqual(3, TestNode.ofOpt(iter.next()).?.key);
    try std.testing.expectEqual(4, TestNode.ofOpt(iter.next()).?.key);
    try std.testing.expectEqual(null, iter.next());
}

fn expectKvEq(expected: anytype, actual: anytype) !void {
    if ((expected == null) != (actual == null))
        return error.TestExpectedEqual;

    if (expected == null) return;

    try std.testing.expectEqual(expected.?.key, actual.?.key);
    try std.testing.expectEqual(expected.?.value, actual.?.value);
}

fn dumpContents(hashmap: std.AutoHashMapUnmanaged(u8, u8), treemap: RedBlackTree) void {
    var it1 = hashmap.iterator();
    std.debug.print("hashmap: [", .{});
    if (it1.next()) |next| std.debug.print("{}", .{next.key_ptr.*});
    while (it1.next()) |next| std.debug.print(", {}", .{next.key_ptr.*});
    std.debug.print("]\n", .{});

    var it2 = treemap.iterator();
    std.debug.print("treemap: [", .{});
    if (it2.next()) |next| std.debug.print("{}", .{TestNode.of(next).key});
    while (it2.next()) |next| std.debug.print(", {}", .{TestNode.of(next).key});
    std.debug.print("]\n", .{});

    treemap.debug(TestNode.print);
}

test "fuzz" {
    const op_limit = 128;
    const key_limit = 64;

    try std.testing.fuzz({}, struct {
        fn testOne(_: void, _input: []const u8) anyerror!void {
            if (!@import("builtin").fuzz) return;

            var input = _input;

            const TreeMap = RedBlackTree;
            const HashMap = std.AutoHashMapUnmanaged(u8, u8);

            var nodes: std.heap.MemoryPool(TestNode) = .init(std.testing.allocator);
            defer nodes.deinit();

            var treemap: TreeMap = .{};
            var hashmap: HashMap = .{};
            defer hashmap.deinit(std.testing.allocator);

            var ops_left: u8 = op_limit;

            while (true) {
                if (ops_left == 0) break;
                ops_left -= 1;

                if (input.len < 1) break;
                const opcode: u8 = input[0];
                input = input[1..];

                if (input.len < 1) break;
                const key = std.mem.readInt(u8, input[0..1], .little) % key_limit;
                input = input[1..];

                switch (@as(u2, @truncate(opcode % 3))) {
                    0 => {
                        if (input.len < 1) break;
                        const val = std.mem.readInt(u8, input[0..1], .little);
                        input = input[1..];

                        std.debug.print("fetchPut(key={}, val={}, size={})\n", .{
                            key,
                            val,
                            treemap.size,
                        });

                        const node: *TestNode = try nodes.create();
                        node.* = .{ .key = key, .value = val };

                        const v1 = treemap.put(TestNode.cmp, &node.node);
                        const v2 = try hashmap.fetchPut(std.testing.allocator, key, val);

                        std.debug.print("hashmap -> {any}\n", .{v2});
                        std.debug.print("rb-tree -> {?f}\n", .{TestNode.ofOpt(v1)});
                        dumpContents(hashmap, treemap);

                        try expectKvEq(v2, TestNode.ofOpt(v1));
                    },
                    1 => {
                        std.debug.print("fetchRemove(key={}, size={})\n", .{
                            key,
                            treemap.size,
                        });

                        const fetcher: TestNode = .{ .key = key };
                        const v1 = treemap.findRemove(TestNode.cmp, &fetcher.node);
                        const v2 = hashmap.fetchRemove(key);

                        std.debug.print("hashmap -> {any}\n", .{v2});
                        std.debug.print("rb-tree -> {?f}\n", .{TestNode.ofOpt(v1)});
                        dumpContents(hashmap, treemap);

                        try expectKvEq(v2, TestNode.ofOpt(v1));
                    },
                    2 => {
                        std.debug.print("get(key={}, size={})\n", .{
                            key,
                            treemap.size,
                        });

                        const fetcher: TestNode = .{ .key = key };
                        const v1 = treemap.get(TestNode.cmp, &fetcher.node);
                        const v2 = hashmap.get(key);

                        std.debug.print("hashmap -> {any}\n", .{v2});
                        std.debug.print("rb-tree -> {any}\n", .{TestNode.valueOpt(v1)});
                        dumpContents(hashmap, treemap);

                        try std.testing.expectEqual(v2, TestNode.valueOpt(v1));
                    },
                    3 => {},
                }

                {
                    // check that all treemap entries are in the hashmap and are the same
                    var it = treemap.iterator();
                    while (it.next()) |next_| {
                        const next = TestNode.of(next_);
                        const expected_val = hashmap.get(next.key).?;
                        try std.testing.expectEqual(expected_val, next.value);
                    }
                }
                {
                    // check that all hashmap entries are in the treemap and are the same
                    var it = hashmap.iterator();
                    while (it.next()) |next_| {
                        const fetcher: TestNode = .{ .key = next_.key_ptr.* };
                        const expected = TestNode.of(treemap.get(TestNode.cmp, &fetcher.node).?);
                        try std.testing.expectEqual(expected.key, next_.key_ptr.*);
                        try std.testing.expectEqual(expected.value, next_.value_ptr.*);
                    }
                }

                treemap.verify(TestNode.cmp);
                try std.testing.expectEqual(hashmap.size, treemap.size);
            }

            try std.testing.expectEqual(hashmap.count(), treemap.size);
        }
    }.testOne, .{});
}
