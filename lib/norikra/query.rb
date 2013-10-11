require 'java'
require 'esper-4.9.0.jar'
require 'esper/lib/commons-logging-1.1.1.jar'
require 'esper/lib/antlr-runtime-3.2.jar'
require 'esper/lib/cglib-nodep-2.2.jar'

require 'norikra/error'
require 'norikra/query/ast'
require 'norikra/field'

module Norikra
  class Query
    attr_accessor :name, :group, :expression, :statement_name, :fieldsets

    def initialize(param={})
      @name = param[:name]
      @group = param[:group] # default nil
      @expression = param[:expression]
      @statement_name = nil
      @fieldsets = {} # { target => fieldset }
      @ast = nil
      @targets = nil
      @aliases = nil
      @subqueries = nil
      @fields = nil
    end

    def dup
      self.class.new(:name => @name, :group => @group, :expression => @expression.dup)
    end

    def to_hash
      {'name' => @name, 'group' => @group, 'expression' => @expression, 'targets' => self.targets}
    end

    def targets
      return @targets if @targets
      @targets = (self.ast.listup(:stream).map(&:target) + self.subqueries.map(&:targets).flatten).sort.uniq
      @targets
    end

    def aliases
      return @aliases if @aliases
      @aliases = (self.ast.listup(:stream).map(&:alias) + self.subqueries.map(&:aliases).flatten).sort.uniq
      @aliases
    end

    def subqueries
      return @subqueries if @subqueries
      @subqueries = self.ast.listup(:subquery).map{|n| Norikra::SubQuery.new(n)}
      @subqueries
    end

    def explore(outer_targets=[], alias_overridden={})
      fields = {}
      alias_map = {}.merge(alias_overridden)

      all = []
      unknowns = []
      self.ast.listup(:stream).each do |node|
        if node.alias
          alias_map[node.alias] = node.target
        end
        fields[node.target] = []
      end

      dup_aliases = (alias_map.keys & fields.keys)
      unless dup_aliases.empty?
        raise Norikra::ClientError, "Invalid alias '#{dup_aliases.join(',')}', same with target name"
      end

      default_target = fields.keys.size == 1 ? fields.keys.first : nil

      outer_targets.each do |t|
        fields[t] ||= []
      end

      field_bag = []
      self.subqueries.each do |subquery|
        field_bag.push(subquery.explore(fields.keys, alias_map))
      end

      known_targets_aliases = fields.keys + alias_map.keys
      self.ast.fields(default_target, known_targets_aliases).each do |field_def|
        f = field_def[:f]
        all.push(f)

        if field_def[:t]
          t = alias_map[field_def[:t]] || field_def[:t]
          unless fields[t]
            raise Norikra::ClientError, "unknown target alias name for: #{field_def[:t]}.#{field_def[:f]}"
          end
          fields[t].push(f)

        else
          unknowns.push(f)
        end
      end

      field_bag.each do |bag|
        all += bag['']
        unknowns += bag[nil]
        bag.keys.each do |t|
          fields[t] ||= []
          fields[t] += bag[t]
        end
      end

      fields.keys.each do |target|
        fields[target] = fields[target].sort.uniq
      end
      fields[''] = all.sort.uniq
      fields[nil] = unknowns.sort.uniq

      fields
    end

    def fields(target='')
      # target '': fields for all targets (without target name)
      # target nil: fields for unknown targets
      return @fields[target] if @fields

      @fields = explore()
      @fields[target]
    end

    class ParseRuleSelectorImpl
      include com.espertech.esper.epl.parse.ParseRuleSelector
      def invokeParseRule(parser)
        parser.startEPLExpressionRule().getTree()
      end
    end

    def ast
      return @ast if @ast
      rule = ParseRuleSelectorImpl.new
      target = @expression.dup
      forerrmsg = @expression.dup
      result = com.espertech.esper.epl.parse.ParseHelper.parse(target, forerrmsg, true, rule, false)

      @ast = astnode(result.getTree)
      @ast
    rescue Java::ComEspertechEsperClient::EPStatementSyntaxException => e
      raise Norikra::QueryError, e.message
    end

    def self.rewrite_query(statement_model, mapping)
      rewrite_event_type_name(statement_model, mapping)
      rewrite_event_field_name(statement_model, mapping)
    end

    def self.rewrite_event_field_name(statement_model, mapping)
      # mapping: {target_name => query_event_type_name}
      #  mapping is for target name rewriting of fully qualified field name access


      # model.getFromClause.getStreams[0].getViews[0].getParameters[0].getPropertyName

      # model.getSelectClause.getSelectList[0].getExpression.getPropertyName
      # model.getSelectClause.getSelectList[0].getExpression.getChildren[0].getPropertyName #=> 'field.key1.$0'

      # model.getWhereClause.getChildren[1].getChildren[0].getPropertyName #=> 'field.key1.$1'
      # model.getWhereClause.getChildren[2].getChildren[0].getChain[0].getName #=> 'opts.num.$0' from opts.num.$0.length()

      query = Norikra::Query.new(:expression => statement_model.toEPL)
      targets = query.targets
      fqfs_prefixes = targets + query.aliases

      default_target = (targets.size == 1 ? targets.first : nil)

      rewrite_name = lambda {|node,getter,setter|
        name = node.send(getter)
        if name && name.index('.')
          prefix = nil
          body = nil
          first_part = name.split('.').first
          if fqfs_prefixes.include?(first_part) or mapping.has_key?(first_part) # fully qualified field specification
            prefix = first_part
            if mapping[prefix]
              prefix = mapping[prefix]
            end
            body = name.split('.')[1..-1].join('.')
          elsif default_target # default target field (outside of join context)
            body = name
          else
            raise Norikra::QueryError, "target cannot be determined for field '#{name}'"
          end
          encoded = (prefix ? "#{prefix}." : "") + Norikra::Field.escape_name(body)
          node.send(setter, encoded)
        end
      }

      rewriter = lambda {|node|
        if node.respond_to?(:getPropertyName)
          rewrite_name.call(node, :getPropertyName, :setPropertyName)
        elsif node.respond_to?(:getChain)
          node.getChain.each do |chain|
            rewrite_name.call(chain, :getName, :setName)
          end
        end
      }
      recaller = lambda {|node|
        Norikra::Query.rewrite_event_field_name(node.getModel, mapping)
      }

      traverse_fields(rewriter, recaller, statement_model)
    end

    def self.rewrite_event_type_name(statement_model, mapping)
      # mapping: {target_name => query_event_type_name}

      ### esper-4.9.0/esper/doc/reference/html/epl_clauses.html#epl-subqueries
      # Subqueries can only consist of a select clause, a from clause and a where clause.
      # The group by and having clauses, as well as joins, outer-joins and output rate limiting are not permitted within subqueries.

      # model.getFromClause.getStreams[0].getFilter.setEventTypeName("hoge")

      # model.getSelectClause.getSelectList[1].getExpression => #<Java::ComEspertechEsperClientSoda::SubqueryExpression:0x3344c133>
      # model.getSelectClause.getSelectList[1].getExpression.getModel.getFromClause.getStreams[0].getFilter.getEventTypeName
      # model.getWhereClause.getChildren[1]                 .getModel.getFromClause.getStreams[0].getFilter.getEventTypeName

      statement_model.getFromClause.getStreams.each do |stream|
        target_name = stream.getFilter.getEventTypeName
        unless mapping[target_name]
          raise RuntimeError, "target missing in mapping, maybe BUG"
        end
        stream.getFilter.setEventTypeName(mapping[target_name])
      end

      rewriter = lambda {|node|
        # nothing for query expression clauses
      }
      recaller = lambda {|node|
        Norikra::Query.rewrite_event_type_name(node.getModel, mapping)
      }
      traverse_fields(rewriter, recaller, statement_model)
    end

    # model.methods.select{|m| m.to_s.start_with?('get')}
    # :getContextName,
    # :getCreateContext,
    # :getCreateDataFlow,
    # :getCreateExpression,
    # :getCreateIndex,
    # :getCreateSchema,
    # :getCreateVariable,
    # :getCreateWindow,
    # :getExpressionDeclarations,
    # :getFireAndForgetClause,
    # :getForClause,
    # (*) :getFromClause,
    # :getGroupByClause,
    # :getHavingClause,
    # :getInsertInto,
    # :getMatchRecognizeClause,
    # :getOnExpr,
    # :getOrderByClause,
    # :getOutputLimitClause,
    # :getRowLimitClause,
    # :getScriptExpressions,
    # (*) :getSelectClause,
    # :getTreeObjectName,
    # :getUpdateClause,
    # (*) :getWhereClause,

    def self.traverse_fields(rewriter, recaller, statement_model)
      #NOTICE: SQLStream is not supported yet.
      #TODO: other clauses with fields, especially: OrderBy, Having, GroupBy, For

      dig = lambda {|node|
        rewriter.call(node)

        if node.is_a?(Java::ComEspertechEsperClientSoda::SubqueryExpression)
          recaller.call(node)
        end
        if node.respond_to?(:getFilter)
          dig.call(node.getFilter)
        end
        if node.respond_to?(:getChildren)
          node.getChildren.each do |c|
            dig.call(c)
          end
        end
        if node.respond_to?(:getParameters)
          node.getParameters.each do |p|
            dig.call(p)
          end
        end
        if node.respond_to?(:getChain)
          node.getChain.each do |c|
            dig.call(c)
          end
        end
      }

      statement_model.getFromClause.getStreams.each do |stream|
        if stream.respond_to?(:getExpression) # PatternStream < ProjectedStream
          dig.call(stream.getExpression)
        end
        if stream.respond_to?(:getFilter) # Filter < ProjectedStream
          dig.call(stream.getFilter.getFilter) #=> Expression
        end
        if stream.respond_to?(:getParameterExpressions) # MethodInvocationStream
          dig.call(stream.getParameterExpressions)
        end
        if stream.respond_to?(:getViews) # ProjectedStream
          stream.getViews.each do |view|
            view.getParameters.each do |parameter|
              dig.call(parameter)
            end
          end
        end
      end

      if statement_model.getSelectClause
        statement_model.getSelectClause.getSelectList.each do |item|
          if item.respond_to?(:getExpression)
            dig.call(item.getExpression)
          end
        end
      end

      if statement_model.getWhereClause
        statement_model.getWhereClause.getChildren.each do |child|
          dig.call(child)
        end
      end

      statement_model
    end
  end

  class SubQuery < Query
    def initialize(ast_nodetree)
      @ast = ast_nodetree
      @targets = nil
      @subqueries = nil
    end

    def ast; @ast; end

    def subqueries
      return @subqueries if @subqueries
      @subqueries = @ast.children.map{|c| c.listup(:subquery)}.reduce(&:+).map{|n| Norikra::SubQuery.new(n)}
      @subqueries
    end

    def name; ''; end
    def expression; ''; end
    def dup; self; end
    def dup_with_stream_name(actual_name); self; end
  end
end
