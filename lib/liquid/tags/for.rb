# frozen_string_literal: true

module Liquid
  # "For" iterates over an array or collection.
  # Several useful variables are available to you within the loop.
  #
  # == Basic usage:
  #    {% for item in collection %}
  #      {{ forloop.index }}: {{ item.name }}
  #    {% endfor %}
  #
  # == Advanced usage:
  #    {% for item in collection %}
  #      <div {% if forloop.first %}class="first"{% endif %}>
  #        Item {{ forloop.index }}: {{ item.name }}
  #      </div>
  #    {% else %}
  #      There is nothing in the collection.
  #    {% endfor %}
  #
  # == Destructuring:
  #    {% for key, value in hash %}
  #      {{ key }}: {{ value }}
  #    {% endfor %}
  #
  # You can also define a limit and offset much like SQL.  Remember
  # that offset starts at 0 for the first item.
  #
  #    {% for item in collection limit:5 offset:10 %}
  #      {{ item.name }}
  #    {% end %}
  #
  #  To reverse the for loop simply use {% for item in collection reversed %} (note that the flag's spelling is different to the filter `reverse`)
  #
  # == Available variables:
  #
  # forloop.name:: 'item-collection'
  # forloop.length:: Length of the loop
  # forloop.index:: The current item's position in the collection;
  #                 forloop.index starts at 1.
  #                 This is helpful for non-programmers who start believe
  #                 the first item in an array is 1, not 0.
  # forloop.index0:: The current item's position in the collection
  #                  where the first item is 0
  # forloop.rindex:: Number of items remaining in the loop
  #                  (length - index) where 1 is the last item.
  # forloop.rindex0:: Number of items remaining in the loop
  #                   where 0 is the last item.
  # forloop.first:: Returns true if the item is the first item.
  # forloop.last:: Returns true if the item is the last item.
  # forloop.parentloop:: Provides access to the parent loop, if present.
  #
  class For < Block
    # Syntax = /\A(#{VariableSegment}+)\s+in\s+(#{QuotedFragment}+)\s*(reversed)?/o
    Syntax = /\A(?<variables> [\w\-,\s]+)\s+in\s+(?<collection> #{QuotedFragment}+)\s*(?<reversed> reversed)?/xo

    attr_reader :collection_name, :variable_name, :limit, :from

    def initialize(tag_name, markup, options)
      super
      @from = @limit = nil
      parse_with_selected_parser(markup)
      @for_block = BlockBody.new
      @else_block = nil
    end

    def parse(tokens)
      return unless parse_body(@for_block, tokens)
      parse_body(@else_block, tokens)
    end

    def nodelist
      @else_block ? [@for_block, @else_block] : [@for_block]
    end

    def unknown_tag(tag, markup, tokens)
      return super unless tag == 'else'
      @else_block = BlockBody.new
    end

    def render_to_output_buffer(context, output)
      segment = collection_segment(context)

      if segment.empty?
        render_else(context, output)
      else
        render_segment(context, output, segment)
      end

      output
    end

    protected

    def lax_parse(markup)
      if markup =~ Syntax
        @variable_names  = Regexp.last_match[:variables].split(",").map(&:strip)
        collection_name  = Regexp.last_match[:collection]
        @reversed        = !!Regexp.last_match[:reversed]
        @name            = "#{@variable_names.join('_')}-#{collection_name}"
        @collection_name = Expression.parse(collection_name)
        markup.scan(TagAttributes) do |key, value|
          set_attribute(key, value)
        end
      else
        raise SyntaxError, options[:locale].t("errors.syntax.for")
      end
    end

    def strict_parse(markup)
      p = Parser.new(markup)

      # first variable name
      @variable_names = [p.consume(:id)]
      # followed by comma separated others
      @variable_names << p.consume(:id) while p.consume?(:comma)

      raise SyntaxError, options[:locale].t("errors.syntax.for_invalid_in") unless p.id?('in')

      collection_name  = p.expression
      @collection_name = Expression.parse(collection_name)

      @name     = "#{@variable_names.join('_')}-#{collection_name}"
      @reversed = p.id?('reversed')

      while p.look(:id) && p.look(:colon, 1)
        unless (attribute = p.id?('limit') || p.id?('offset'))
          raise SyntaxError, options[:locale].t("errors.syntax.for_invalid_attribute")
        end
        p.consume
        set_attribute(attribute, p.expression)
      end
      p.consume(:end_of_string)
    end

    private

    def collection_segment(context)
      offsets = context.registers[:for] ||= {}

      from = if @from == :continue
        offsets[@name].to_i
      else
        from_value = context.evaluate(@from)
        if from_value.nil?
          0
        else
          Utils.to_integer(from_value)
        end
      end

      collection = context.evaluate(@collection_name)
      collection = collection.to_a if collection.is_a?(Range)

      limit_value = context.evaluate(@limit)
      to = if limit_value.nil?
        nil
      else
        Utils.to_integer(limit_value) + from
      end

      segment = Utils.slice_collection(collection, from, to)
      segment.reverse! if @reversed

      offsets[@name] = from + segment.length

      segment
    end

    def render_segment(context, output, segment)
      for_stack = context.registers[:for_stack] ||= []
      length    = segment.length

      context.stack do
        loop_vars = Liquid::ForloopDrop.new(@name, length, for_stack[-1])

        for_stack.push(loop_vars)

        begin
          context['forloop'] = loop_vars

          segment.each do |item|
            if @variable_names.length == 1
              context[@variable_names.first] = item
            else
              @variable_names.each_with_index do |variable_name, index|
                context[variable_name] = item[index]
              end
            end

            @for_block.render_to_output_buffer(context, output)
            loop_vars.send(:increment!)

            # Handle any interrupts if they exist.
            next unless context.interrupt?
            interrupt = context.pop_interrupt
            break if interrupt.is_a?(BreakInterrupt)
            next if interrupt.is_a?(ContinueInterrupt)
          end
        ensure
          for_stack.pop
        end
      end

      output
    end

    def set_attribute(key, expr)
      case key
      when 'offset'
        @from = if expr == 'continue'
          :continue
        else
          Expression.parse(expr)
        end
      when 'limit'
        @limit = Expression.parse(expr)
      end
    end

    def render_else(context, output)
      if @else_block
        @else_block.render_to_output_buffer(context, output)
      else
        output
      end
    end

    class ParseTreeVisitor < Liquid::ParseTreeVisitor
      def children
        (super + [@node.limit, @node.from, @node.collection_name]).compact
      end
    end
  end

  Template.register_tag('for', For)
end
