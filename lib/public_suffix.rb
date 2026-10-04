# frozen_string_literal: true

# = Public Suffix
#
# Domain name parser based on the Public Suffix List.
#
# Copyright (c) 2009-2026 Simone Carletti <weppos@weppos.net>

require_relative "public_suffix/domain"
require_relative "public_suffix/version"
require_relative "public_suffix/errors"
require_relative "public_suffix/rule"
require_relative "public_suffix/list"

# PublicSuffix is a Ruby domain name parser based on the Public Suffix List.
#
# The [Public Suffix List](https://publicsuffix.org) is a cross-vendor initiative
# to provide an accurate list of domain name suffixes.
#
# The Public Suffix List is an initiative of the Mozilla Project,
# but is maintained as a community resource. It is available for use in any software,
# but was originally created to meet the needs of browser manufacturers.
module PublicSuffix

  DOT   = "."
  BANG  = "!"
  STAR  = "*"

  # Parses +name+ and returns the {PublicSuffix::Domain} instance.
  #
  # @example Parse a valid domain
  #   PublicSuffix.parse("google.com")
  #   # => #<PublicSuffix::Domain:0x007fec2e51e588 @sld="google", @tld="com", @trd=nil>
  #
  # @example Parse a valid subdomain
  #   PublicSuffix.parse("www.google.com")
  #   # => #<PublicSuffix::Domain:0x007fec276d4cf8 @sld="google", @tld="com", @trd="www">
  #
  # @example Parse a fully qualified domain
  #   PublicSuffix.parse("google.com.")
  #   # => #<PublicSuffix::Domain:0x007fec257caf38 @sld="google", @tld="com", @trd=nil>
  #
  # @example Parse a fully qualified domain (subdomain)
  #   PublicSuffix.parse("www.google.com.")
  #   # => #<PublicSuffix::Domain:0x007fec27b6bca8 @sld="google", @tld="com", @trd="www">
  #
  # @example Parse an invalid (unlisted) domain
  #   PublicSuffix.parse("x.yz")
  #   # => #<PublicSuffix::Domain:0x007fec2f49bec0 @sld="x", @tld="yz", @trd=nil>
  #
  # @example Parse an invalid (unlisted) domain with strict checking (without applying the default * rule)
  #   PublicSuffix.parse("x.yz", default_rule: nil)
  #   # => PublicSuffix::DomainInvalid: `x.yz` is not a valid domain
  #
  # @example Parse an URL (not supported, only domains)
  #   PublicSuffix.parse("http://www.google.com")
  #   # => PublicSuffix::DomainInvalid: http://www.google.com is not expected to contain a scheme
  #
  #
  # @param  name [#to_s] The domain name or fully qualified domain name to parse.
  # @param  list [PublicSuffix::List] The rule list to search, defaults to the default {PublicSuffix::List}
  # @param  ignore_private [Boolean]
  # @return [PublicSuffix::Domain]
  #
  # @raise [PublicSuffix::DomainInvalid] If domain is not a valid domain.
  # @raise [PublicSuffix::DomainNotAllowed] If a rule for +domain+ is found, but the rule doesn't allow +domain+.
  def self.parse(name, list: List.default, default_rule: list.default_rule, ignore_private: false)
    what = normalize(name)
    raise what if what.is_a?(DomainInvalid)

    rule = list.find(what, default: default_rule, ignore_private: ignore_private)

    # rubocop:disable Style/IfUnlessModifier
    if rule.nil?
      raise DomainInvalid, "`#{what}` is not a valid domain"
    end
    if rule.decompose(what).last.nil?
      raise DomainNotAllowed, "`#{what}` is not allowed according to Registry policy"
    end

    # rubocop:enable Style/IfUnlessModifier

    decompose(what, rule)
  end

  # Checks whether +domain+ is assigned and allowed, without actually parsing it.
  #
  # This method doesn't care whether domain is a domain or subdomain.
  # The validation is performed using the default {PublicSuffix::List}.
  #
  # @example Validate a valid domain
  #   PublicSuffix.valid?("example.com")
  #   # => true
  #
  # @example Validate a valid subdomain
  #   PublicSuffix.valid?("www.example.com")
  #   # => true
  #
  # @example Validate a not-listed domain
  #   PublicSuffix.valid?("example.tldnotlisted")
  #   # => true
  #
  # @example Validate a not-listed domain with strict checking (without applying the default * rule)
  #   PublicSuffix.valid?("example.tldnotlisted")
  #   # => true
  #   PublicSuffix.valid?("example.tldnotlisted", default_rule: nil)
  #   # => false
  #
  # @example Validate a fully qualified domain
  #   PublicSuffix.valid?("google.com.")
  #   # => true
  #   PublicSuffix.valid?("www.google.com.")
  #   # => true
  #
  # @example Check an URL (which is not a valid domain)
  #   PublicSuffix.valid?("http://www.example.com")
  #   # => false
  #
  #
  # @param  name [#to_s] The domain name or fully qualified domain name to validate.
  # @param  ignore_private [Boolean]
  # @return [Boolean]
  def self.valid?(name, list: List.default, default_rule: list.default_rule, ignore_private: false)
    what = normalize(name)
    return false if what.is_a?(DomainInvalid)

    rule = list.find(what, default: default_rule, ignore_private: ignore_private)

    !rule.nil? && !rule.decompose(what).last.nil?
  end

  # Attempt to parse the name and returns the domain, if valid.
  #
  # This method doesn't raise. Instead, it returns nil if the domain is not valid for whatever reason.
  #
  # @param  name [#to_s] The domain name or fully qualified domain name to parse.
  # @param  list [PublicSuffix::List] The rule list to search, defaults to the default {PublicSuffix::List}
  # @param  ignore_private [Boolean]
  # @return [String]
  def self.domain(name, **options)
    parse(name, **options).domain
  rescue PublicSuffix::Error
    nil
  end

  # Compares two Public Suffix Lists and reports the domain families whose
  # registration boundary (eTLD/eTLD+1) changes between them.
  #
  # This is useful before upgrading the bundled list: instead of a textual
  # diff of added/removed rules, the comparison uses the actual matching
  # semantics, so a wildcard rule fully canceled out by an exception rule is
  # not reported as a change.
  #
  # @example Identify affected families before a list upgrade
  #   comparison = PublicSuffix.compare_lists(old_content, new_content)
  #   comparison.changed? # => true
  #   comparison.families # => ["co.uk", "*.co.uk"]
  #   comparison.first.witness # => "co.uk"
  #
  # @example Compare ICANN rules only
  #   PublicSuffix.compare_lists(old_list, new_list, ignore_private: true)
  #
  # @param  old_list [PublicSuffix::List, #each_line] the current list or content
  # @param  new_list [PublicSuffix::List, #each_line] the candidate list or content
  # @param  ignore_private [Boolean] whether to exclude private domains
  # @return [PublicSuffix::List::Comparison]
  def self.compare_lists(old_list, new_list, ignore_private: false)
    List.compare_lists(old_list, new_list, ignore_private: ignore_private)
  end


  # private

  def self.decompose(name, rule)
    left, right = rule.decompose(name)

    parts = left.split(DOT)
    # If we have 0 parts left, there is just a tld and no domain or subdomain
    # If we have 1 part  left, there is just a tld, domain and not subdomain
    # If we have 2 parts left, the last part is the domain, the other parts (combined) are the subdomain
    tld = right
    sld = parts.empty? ? nil : parts.pop
    trd = parts.empty? ? nil : parts.join(DOT)

    Domain.new(tld, sld, trd)
  end

  # Pretend we know how to deal with user input.
  def self.normalize(name)
    name = name.to_s.dup
    name.strip!
    name.chomp!(DOT)
    name.downcase!

    return DomainInvalid.new("Name is blank") if name.empty?
    return DomainInvalid.new("Name starts with a dot") if name.start_with?(DOT)
    return DomainInvalid.new(format("%s is not expected to contain a scheme", name)) if name.include?("://")

    name
  end

end
