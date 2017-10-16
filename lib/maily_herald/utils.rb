module MailyHerald
  module Utils
    def self.random_hex(n)
      SecureRandom.hex(n)
    end

    class MarkupEvaluator
      VariableSignature = /\A[\w\.\[\]]+(\s*|\s*.+)?\Z/

      module Filters
        module Date
          def minus input, no, unit
            input - no.to_i.send(unit)
          end

          def plus input, no, unit
            input + no.to_i.send(unit)
          end
        end
      end

      def self.test_conditions conditions
        return true if !conditions || conditions.empty?

        drop = Class.new(Liquid::Drop) do
          def has_key?(name); true; end
          def invoke_drop(name); true; end
          alias :[] :invoke_drop
        end.new

        evaluator = Utils::MarkupEvaluator.new(drop)
        evaluator.evaluate_conditions(conditions)
        true
      rescue
        return false
      end

      def self.test_start_at markup
        return true if !markup || markup.empty?

        drop = Class.new(Liquid::Drop) do
          def key?(name); true; end
          def invoke_drop(name)
            t = Time.now
            t.define_singleton_method(:[]) do |v|
              Time.now
            end
            t.define_singleton_method(:key?) do |v|
              true
            end
            t
          end
          alias :[] :invoke_drop
        end.new

        evaluator = Utils::MarkupEvaluator.new(drop)
        val = evaluator.evaluate_start_at(markup)

        return val.is_a?(Time) || val.is_a?(DateTime)
      rescue
        return false
      end

      def initialize drop
        @drop = drop
      end

      def evaluate_conditions conditions
        return true if !conditions || conditions.empty?

        condition = MarkupEvaluator.create_liquid_condition conditions
        template = Liquid::Template.parse(conditions)
        raise StandardError unless template.errors.empty?

        liquid_context = Liquid::Context.new([@drop, template.assigns], template.instance_assigns, template.registers, true, {})
        @drop.context = liquid_context if @drop.is_a?(Liquid::Drop)

        val = condition.evaluate liquid_context
        raise(ArgumentError, "Conditions do not evaluate to boolean (got `#{val}`)") unless [true, false].include?(val)
        val
      end

      def evaluate_start_at markup
        begin
          Time.parse(markup)
        rescue
          raise(ArgumentError, "Start at is not a proper variable: `#{markup}`") unless VariableSignature =~ markup

          liquid_context = Liquid::Context.new([@drop], {}, {}, true, {})
          liquid_context.add_filters([Filters::Date])

          @drop.context = liquid_context if @drop.is_a?(Liquid::Drop)
          #liquid_context[markup]

          parse_context = Class.new do
            def line_number; 1; end
            def error_mode; :lax; end
          end.new
          variable = Liquid::Variable.new markup, parse_context
          variable.render(liquid_context)
        end
      end

      private

      def self.create_liquid_condition markup
        expressions = markup.scan(Liquid::If::ExpressionsAndOperators)
        raise(Liquid::SyntaxError.new(options[:locale].t("errors.syntax.if".freeze))) unless expressions.pop =~ Liquid::If::Syntax

        condition = Liquid::Condition.new(Liquid::Expression.parse($1), $2, Liquid::Expression.parse($3))

        until expressions.empty?
          operator = expressions.pop.to_s.strip

          raise(Liquid::SyntaxError.new(options[:locale].t("errors.syntax.if".freeze))) unless expressions.pop.to_s =~ Liquid::If::Syntax

          new_condition = Liquid::Condition.new(Liquid::Expression.parse($1), $2, Liquid::Expression.parse($3))
          raise(Liquid::SyntaxError.new(options[:locale].t("errors.syntax.if".freeze))) unless Liquid::If::BOOLEAN_OPERATORS.include?(operator)
          new_condition.send(operator, condition)
          condition = new_condition
        end

        condition
      end
    end
  end
end
