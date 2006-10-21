require File.dirname(__FILE__) + '/helpers'
require File.dirname(__FILE__) + '/buffer'
require 'profiler'

module Haml
  # This is the class where all the parsing and processing of the HAML
  # template is done. It can be directly used by the user by creating a
  # new instance and calling to_html to render the template. For example:
  # 
  #   template = File.load('templates/really_cool_template.haml')
  #   haml_engine = Haml::Engine.new(template)
  #   output = haml_engine.to_html
  #   puts output
  class Engine
    include Haml::Helpers

    # Allow access to the precompiled template
    attr_reader :precompiled
    
    # Keeps track of the ASCII values of the characters that begin a 
    # specially-interpreted line.
    SPECIAL_CHARACTERS   = %w(# . = ~ % /).collect { |c| c[0] }

    # The value of the character that designates that a line is part
    # of a multiline string.
    MULTILINE_CHAR_VALUE = '|'[0]
    
    # Characters that designate that a multiline string may be about
    # to begin.
    MULTILINE_STARTERS   = SPECIAL_CHARACTERS - ["/"[0]]
    
    # Keywords that appear in the middle of a Ruby block with lowered
    # indentation. If a block has been started using indentation,
    # lowering the indentation  with one of these won't end the block.
    # For example:
    # 
    #   - if foo
    #     %p yes!
    #   - else
    #     %p no!
    # 
    # The block is ended after <tt>%p no!</tt>, because <tt>else</tt>
    # is a member of this array.
    MID_BLOCK_KEYWORDS   = ['else', 'elsif', 'rescue', 'ensure', 'when']

    # Creates a new instace of Haml::Engine to compile the given
    # template string.
    # 
    # Available options are:
    # 
    # [<tt>scope_object</tt>]  The object within which the template will
    #                          be compiled, via instance_eval. For a Rails
    #                          application, this will typically be an
    #                          instance of ActionView::Base. If not specified,
    #                          this defaults to an instance of the Object class.
    # [<tt>suppress_eval</tt>] Whether or not attribute hashes and Ruby scripts
    #                          designated by <tt>=</tt> or <tt>~</tt> should be
    #                          evaluated. If this is true, said scripts are
    #                          rendered as empty strings. Defaults to false.
    def initialize(template, options = {})
      #turn each of the options into instance variables for the object
      options.each { |k,v| eval("@#{k} = v") }

      @template = template #String
      @buffer = Haml::Buffer.new

      @to_close_stack = []
      @tabulation = 0

      # Only do the first round of pre-compiling if we really need to.
      # They might be passing in the precompiled string.
      do_precompile if @precompiled.nil? && (@precompiled = String.new)
    end

    # Processes the template and returns the resulting (X)HTML code as
    # a string.
    def to_html(scope = Object.new)
      @scope = scope

      # Compile the @precompiled buffer
      compile

      # Return the result string
      @buffer.buffer
    end
    
   private
    
    #Precompile each line
    def do_precompile
      @template.each_with_index do |line, index|
        count, line = count_soft_tabs(line)
        suppress_render = handle_multiline(count, line, index)
  
        if !suppress_render && count && line
          count, line = process_line(count, line, index)
        end
      end
  
      # Make sure an ending multiline gets closed
      handle_multiline(0, nil, 0)
  
      # Close all the open tags
      @to_close_stack.length.times { close }
    end
    
    # Processes a single line of HAML. <tt>count</tt> does *not* represent the
    # line number; rather, it represents the tabulation count (the number of
    # spaces before the line divided by two).
    # 
    # This method doesn't return anything; it simply processes the line and
    # adds the appropriate code to <tt>@precompiled</tt>.
    def process_line(count, line, index)
      if line.lstrip[0, 3] == '!!!'
        push_text '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">'
        
      else
        if count > @to_close_stack.size
        
          # Indentation has been increased without a new tag
          if @latest_command == 45 # '-'
          
            # The indentation was increased after silent script,
            # it must be a block
            @to_close_stack.push '_haml_end_block'
          end
          
        elsif count <= @to_close_stack.size && @to_close_stack.size > 0 &&
            (line.length == 0 || line[0] != 45 || !MID_BLOCK_KEYWORDS.include?(line[1..-1].split[0]))
            
          # The tabulation has gone down, and it's not because of one of
          # Ruby's mid-block keywords
          (@to_close_stack.size - count).times { close }
        end
        
        if line.length > 0
          @latest_command = line[0]
          case @latest_command
          when 46, 35 # '.', '#'
            render_div(line, index)
          when 37 # '%'
            render_tag(line, index)
          when 47 # '/'
            render_comment(line)
          when 61 # '='
            push_script(line[1..-1], false, index)
          when 126 # '~'
            push_script(line[1..-1], true, index)
          when 45 # '-'
            sub_line = line[1..-1]
            unless sub_line[0] == 35 # '#'
              push_silent(sub_line, index)
            else
              @latest_command = 35
            end
          else
            push_text line.strip
          end
        end
        
      end
    end

    # Deals with all the logic of figuring out whether a given line is
    # the beginning, continuation, or end of a multiline sequence. Like
    # process_line, <tt>count</tt> represents the tabulation, not line
    # number.
    # 
    # This returns whether or not the line should be
    # rendered normally.
    def handle_multiline(count, line, index)
      # Multilines are denoting by ending with a `|` (124)
      if line && (line[-1] == MULTILINE_CHAR_VALUE) && @multiline_buffer
        # A multiline string is active, and is being continued 
        @multiline_buffer += line[0...-1]
        suppress_render = true
      elsif line && (line[-1] == MULTILINE_CHAR_VALUE) && (MULTILINE_STARTERS.include? line[0])
        # A multiline string has just been activated, start adding the lines
        @multiline_buffer = line[0...-1]
        @multiline_count = count
        @multiline_index = index
        suppress_render = true
      elsif @multiline_buffer
        # A multiline string has just ended, make line into the result
        process_line(@multiline_count, @multiline_buffer, @multiline_index)
        @multiline_buffer = nil
        suppress_render = false
      end

      return suppress_render
    end

    # Takes <tt>@precompiled</tt>, a string buffer of Ruby code, and
    # evaluates it in the context of <tt>@scope_object</tt>, after preparing
    # <tt>@scope_object</tt>. The code in <tt>@precompiled</tt> populates
    # <tt>@buffer</tt> with the compiled XHTML code.
    def compile
      # Set the local variables pointing to the buffer
      buffer = @buffer
      @scope_object.instance_eval do
        @haml_stack ||= Array.new
        @haml_stack.push(buffer)
        self.class.instance_eval { include Haml::Helpers }
        
        class << self
          attr :haml_lineno
        end
      end
      
      @precompiled = <<END
_hamlout = @haml_stack[-1]
_erbout = _hamlout.buffer
#{@precompiled}
END
      
      begin
        # Evaluate the buffer in the context of the scope object
        @scope_object.instance_eval @precompiled
      rescue Exception => e
        # Get information from the exception and format it so that
        # Rails can understand it.
        compile_error = e.message.scan(/\(eval\):([0-9]*):in `[-_a-zA-Z]*': compile error/)[0]
        filename = "(haml)"
        if @scope_object.methods.include? "haml_filename"
          # For some reason that I can't figure out,
          # @scope_object.methods.include? "haml_filename" && @scope_object.haml_filename
          # is false when it shouldn't be. Nested if statements work, though.
          
          if @scope_object.haml_filename
            filename = "#{@scope_object.haml_filename}.haml"
          end
        end
        lineno = @scope_object.haml_lineno
        
        if compile_error
          eval_line = compile_error[0].to_i
          line_marker = @precompiled.split("\n")[0...eval_line].grep(/@haml_lineno = [0-9]*/)[-1]
          lineno = line_marker.scan(/[0-9]+/)[0].to_i if line_marker
        end
        
        e.backtrace.unshift "#{filename}:#{lineno}"
        raise e
      end
      
      # Get rid of the current buffer
      @scope_object.instance_eval do
        @haml_stack.pop
      end      
    end

    # Evaluates <tt>text</tt> in the context of <tt>@scope_object</tt>, but
    # does not output the result.
    def push_silent(text, index = nil)
      if index
        @precompiled << "@haml_lineno = #{index + 1}\n#{text}\n"
      else
        # Not really DRY, but probably faster
        @precompiled << "#{text}\n"
      end
    end

    # Adds <tt>text</tt> to <tt>@buffer</tt> with appropriate tabulation
    # without parsing it.
    def push_text(text)
      @precompiled << "_hamlout.push_text(#{text.dump}, #{@tabulation})\n"
    end

    # Causes <tt>text</tt> to be evaluated in the context of
    # <tt>@scope_object</tt> and the result to be added to <tt>@buffer</tt>.
    # 
    # If <tt>flattened</tt> is true, Haml::Helpers#find_and_flatten is run on
    # the result before it is added to <tt>@buffer</tt>
    def push_script(text, flattened, index)
      unless @suppress_eval
        push_silent("haml_temp = #{text}", index)
        @precompiled << "haml_temp = _hamlout.push_script(haml_temp, #{@tabulation}, #{flattened})\n"
      end
    end

    # Closes the most recent item in <tt>@to_close_stack</tt>.
    def close
      tag = @to_close_stack.pop
      if tag == '_haml_end_block'
        close_block
      else
        close_tag tag
      end
    end

    # Puts a line in <tt>@precompiled</tt> that will add the closing tag of
    # the most recently opened tag.
    def close_tag(tag)
      @tabulation -= 1
      @precompiled << "_hamlout.close_tag(#{tag.dump}, #{@tabulation})\n"
    end
    
    # Closes a Ruby block.
    def close_block
      push_silent "end"
    end

    # Parses a line that will render as an XHTML tag, and adds the code that will
    # render that tag to <tt>@precompiled</tt>.
    def render_tag(line, index)
      line.scan(/[%]([-_a-z1-9]+)([-_a-z\.\#]*)(\{.*\})?(\[.*\])?([=\/\~]?)?(.*)?/) do |tag_name, attributes, attributes_hash, object_ref, action, value|
        value = value.to_s
      
        case action
        when '/'
          atomic = true
        when '=', '~'
          flattened = (action == '~')
          parse = true
        else
          value = value.strip
        end
        
        value_exists = !value.empty?
        attributes_hash = "nil" unless attributes_hash
        object_ref = "nil" unless object_ref
        
        @precompiled << "_hamlout.open_tag(#{tag_name.inspect}, #{@tabulation}, #{atomic.inspect}, #{value_exists.inspect}, #{attributes.inspect}, #{attributes_hash}, #{object_ref})\n"
        
        unless atomic
          @to_close_stack.push tag_name
          @tabulation += 1
          
          if value_exists
            if parse
              push_script(value, flattened, index)
            else
              push_text(value)
            end
            close
          end
        end
      end
    end

    # Renders a line that creates an XHTML tag and has an implicit div because of
    # <tt>.</tt> or <tt>#</tt>.
    def render_div(line, index)
      render_tag('%div' + line, index)
    end

    # Renders an XHTML comment.
    def render_comment(line)
      push_text "<!-- #{line[1..line.length].strip} -->"
    end
  end
end
