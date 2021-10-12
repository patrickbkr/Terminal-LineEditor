# ABSTRACT: Core roles for abstract editable buffers


#| General exceptions for Terminal::LineEditor
class X::Terminal::LineEditor is Exception { }

#| Invalid buffer position
class X::Terminal::LineEditor::InvalidPosition is X::Terminal::LineEditor {
    has $.pos    is required;
    has $.reason is required;

    method message() { "Invalid editable buffer position: $!reason" }
}

#| Invalid or non-existant cursor
class X::Terminal::LineEditor::InvalidCursor is X::Terminal::LineEditor {
    has $.id     is required;
    has $.reason is required;

    method message() { "Invalid cursor: $!reason" }
}


#| Simple wrapper for undo/redo record pairs
class Terminal::LineEditor::UndoRedo {
    has $.undo;
    has $.redo;
}


#| Core methods for any editable buffer
role Terminal::LineEditor::EditableBuffer {
    method contents()             { ... }
    method ensure-pos-valid($pos) { ... }
    method insert($pos, $content) { ... }
    method delete($start, $after) { ... }
    # XXXX: Support out-of-order undo/redo
    method undo()                 { ... }
    method redo()                 { ... }
}


#| Core functionality for a single line text buffer
class Terminal::LineEditor::SingleLineTextBuffer
 does Terminal::LineEditor::EditableBuffer {
    has Str:D $.contents = '';
    has @.undo-records;
    has @.redo-records;


    ### INVARIANT HELPERS

    #| Throw an exception if a position is out of bounds or the wrong type
    method ensure-pos-valid($pos, Bool:D :$allow-end = True) {
        X::Terminal::LineEditor::InvalidPosition.new(:$pos, :reason('position is not a defined nonnegative integer')).throw
            unless $pos ~~ Int && $pos.defined && $pos >= 0;

        X::Terminal::LineEditor::InvalidPosition.new(:$pos, :reason('position is beyond the buffer end')).throw
            unless $pos < $!contents.chars + $allow-end;
    }


    ### LOW-LEVEL OPERATION APPLIERS

    #| Apply a (previously validated) insert operation against current contents
    multi method apply-operation('insert', $pos, $content) {
        substr-rw($!contents, $pos, 0) = $content;
    }

    #| Apply a (previously validated) delete operation against current contents
    multi method apply-operation('delete', $start, $after) {
        substr-rw($!contents, $start, $after - $start) = '';
    }

    #| Apply a (previously validated) replace operation against current contents
    multi method apply-operation('replace', $start, $after, $replacement) {
        substr-rw($!contents, $start, $after - $start) = $replacement;
    }


    ### INTERNAL UNDO/REDO CORE

    #| Create an undo/redo record pair for an insert operation
    multi method create-undo-redo-record('insert', $pos, $content) {
        # The complexity below is because the inserted string might start with
        # combining characters, and thus due to NFG renormalization insert-pos
        # should move less than the full length of the inserted string.

        # XXXX: This is slow (doing a string copy), but until there is a fast
        # solution for calculating the combined section and replacement length,
        # it will have to do.
        my $temp      = $.contents;
        my $before    = $temp.chars;
        substr-rw($temp, $pos, 0) = $content;
        my $after-pos = $pos + $temp.chars - $before;

        # XXXX: This is likely incorrect for modern Unicode
        my $combined-section = $pos ?? substr($pos - 1, 1) !! '';
        my $combined-start   = $pos - $combined-section.chars;

        $combined-section
        ?? Terminal::LineEditor::UndoRedo.new(
            :redo('replace', $combined-start, $pos, $combined-section ~ $content),
            :undo('replace', $combined-start, $after-pos, $combined-section))
        !! Terminal::LineEditor::UndoRedo.new(
            :redo('insert',  $pos, $content),
            :undo('delete',  $pos, $after-pos))
    }

    #| Create an undo/redo record pair for a delete operation
    multi method create-undo-redo-record('delete', $start, $after) {
        # Complexity from insert case not needed because start and end refer to
        # whole grapheme cluster positions, so we don't end up with split
        # grapheme clusters.

        my $to-delete = substr($.contents, $start, $after - $start);
        Terminal::LineEditor::UndoRedo.new(
            :redo('delete', $start, $after),
            :undo('insert', $start, $to-delete))
    }

    #| Execute an undo record against current contents
    method do-undo-record($record) {
        self.apply-operation(|$record.undo);
        @.redo-records.push($record);
    }

    #| Execute a do/redo record against current contents
    method do-redo-record($record) {
        self.apply-operation(|$record.redo);
        @.undo-records.push($record);
    }

    #| Start a new branch of the undo/redo tree (insert or delete after undo)
    method new-redo-branch() {
        # Simply drop the old redo list, keeping a single linear undo/redo list
        @!redo-records = ();
    }


    ### EXTERNAL EDIT COMMANDS

    #| Insert a substring at a given position
    method insert($pos, Str:D $content) {
        self.ensure-pos-valid($pos);

        self.new-redo-branch;
        my $record = self.create-undo-redo-record('insert', $pos, $content);
        self.do-redo-record($record);
    }

    #| Delete a substring at a given position range
    method delete($start, $end) {
        self.ensure-pos-valid($_) for $start, $end;

        self.new-redo-branch;
        my $record = self.create-undo-redo-record('delete', $start, $end);
        self.do-redo-record($record);
    }

    #| Undo the previous edit (or silently do nothing if no edits left)
    method undo() {
        self.do-undo-record(@.undo-records.pop) if @.undo-records;
    }

    #| Redo a previously undone edit (or silently do nothing if no undos left)
    method redo() {
        self.do-redo-record(@.redo-records.pop) if @.redo-records;
    }
}



#| A cursor for a SingleLineTextBuffer
class Terminal::LineEditor::SingleLineTextBuffer::Cursor {
    has Terminal::LineEditor::SingleLineTextBuffer:D $.buffer is required;
    has UInt:D $.pos = 0;
    has $.id is required;

    # XXXX: Should there be other failure modes if moving outside contents?

    #| Calculate end position (greatest possible insert position)
    method end() {
        $.buffer.contents.chars
    }

    #| Determine if cursor is already at the end
    method at-end() {
        $.pos == self.end
    }

    #| Move to an absolute position in the buffer; returns new position
    method move-to(UInt:D $pos) {
        # Silently clip to end of buffer
        my $end = self.end;
        $pos = $end if $pos > $end;

        $!pos = $pos;
    }

    #| Move relative to current position; returns new position
    method move-rel(Int:D $delta) {
        # Silently clip to buffer
        my $pos = $!pos + $delta;
        my $end = self.end;

        $!pos = $pos < 0    ?? 0    !!
                $pos > $end ?? $end !!
                               $pos;
    }
}


#| A SingleLineTextBuffer with (possibly several) active insert cursors
class Terminal::LineEditor::SingleLineTextBuffer::WithCursors
   is Terminal::LineEditor::SingleLineTextBuffer {
    has $.cursor-class = Terminal::LineEditor::SingleLineTextBuffer::Cursor;
    has atomicint $.next-id = 0;
    has %.cursors;


    ### INVARIANT HELPERS

    #| Throw an exception if a cursor ID doesn't exist
    method ensure-cursor-exists($id) {
        X::Terminal::LineEditor::InvalidCursor.new($id, :reason('cursor ID does not exist')).throw
            unless $id ~~ Cool && $id.defined && (%!cursors{$id}:exists);
    }


    ### LOW-LEVEL OPERATION APPLIERS, NOW CURSOR-AWARE

    #| Apply a (previously validated) insert operation against current contents
    multi method apply-operation('insert', $pos, $content) {
        my $before = $.contents.chars;
        callsame;
        my $delta  = $.contents.chars - $before;

        for @.cursors {
            .move-rel($delta) if .pos >= $pos;
        }
    }

    #| Apply a (previously validated) delete operation against current contents
    multi method apply-operation('delete', $start, $after) {
        callsame;
        my $delta = $after - $start;

        for @.cursors {
            if    .pos >= $after { .move-rel(-$delta) }
            elsif .pos >= $start { .move-to($start) }
        }
    }

    #| Apply a (previously validated) replace operation against current contents
    multi method apply-operation('replace', $start, $after, $replacement) {
        my $before = $.contents.chars;
        callsame;
        my $delta  = $.contents.chars - $before;

        for @.cursors {
            if    .pos >= $after { .move-rel($delta) }
            elsif .pos >= $start { .move-to($delta + $start) }
        }
    }


    ### CURSOR MANAGEMENT

    #| Create a new cursor at $pos (defaulting to buffer start, pos 0),
    #| returning cursor ID (assigned locally to this buffer)
    method add-cursor(UInt:D $pos = 0) {
        self.ensure-pos-valid($pos);

        my $id = ++⚛$!next-id;
        %!cursors{$id} = $.cursor-class.new(:$id, :$pos, :buffer(self));
    }

    #| Return cursor object for a given cursor ID
    method cursor(UInt:D $id) {
        self.ensure-cursor-exists($id);

        %!cursors{$id}
    }

    #| Delete the cursor object for a given cursor ID
    method delete-cursor(UInt:D $id) {
        self.ensure-cursor-exists($id);

        %!cursors{$id}:delete
    }
}
