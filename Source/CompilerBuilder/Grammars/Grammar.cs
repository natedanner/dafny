﻿// See https://aka.ms/new-console-template for more information

using System.Net.Http.Headers;
using Microsoft.Dafny;

namespace CompilerBuilder;

public abstract class Grammar {
  public static implicit operator Grammar(string keyword) => new Text(keyword);
}

public abstract class Grammar<T>;

class Many<T>(Grammar<T> one) : Grammar<List<T>>;

class SkipLeft<T>(Grammar left, Grammar<T> right) : Grammar<T>;

class SkipRight<T>(Grammar<T> left, Grammar right) : Grammar<T>;
  
class Text(string value) : Grammar;

internal class NumberG : Grammar<int>;

internal class IdentifierG : Grammar<string>;

class WithRange<T, U>(Grammar<T> grammar, Func<RangeToken, T, U> map) : Grammar<U>;

class Value<T>(T value) : Grammar<T>;

class Sequence<TContainer>(Grammar<Action<TContainer>> left, Grammar<Action<TContainer>> right) : Grammar<Action<TContainer>>;

public static class GrammarExtensions {
  public static Grammar<T> InBraces<T>(this Grammar<T> grammar) {
    return GrammarBuilder.Keyword("{").Then(grammar).Then("}");
  }  
  
  public static Grammar<T> Then<T>(this Grammar<T> left, Grammar right) {
    return new SkipRight<T>(left, right);
  }  
  
  public static Grammar<T> Then<T>(this Grammar left, Grammar<T> right) {
    return new SkipLeft<T>(left, right);
  }
  public static Grammar<List<T>> Many<T>(this Grammar<T> one) {
    return new Many<T>(one);
  }
  
  public static Grammar<U> Map<T, U>(this Grammar<T> grammar, Func<RangeToken, T,U> map) {
    return new WithRange<T, U>(grammar, map);
  }
  
  public static Grammar<U> Map<T, U>(this Grammar<T> grammar, Func<T,U> map) {
    return new WithRange<T, U>(grammar, (_, original) => map(original));
  }
  
  public static Grammar<Action<TContainer>> Then<TContainer>(
    this Grammar<Action<TContainer>> left,
    Grammar<Action<TContainer>> right) {
    return new Sequence<TContainer>(left, right);
  }

  public static Grammar<T> Build<T>(this Grammar<Action<T>> grammar, T value) {
    return grammar.Map(builder => {
      builder(value);
      return value;
    });
  }
  
  public static Grammar<Action<TContainer>> Then<TContainer, TValue>(
    this Grammar<Action<TContainer>> containerGrammar, 
    Grammar<TValue> value, 
    Action<TContainer, TValue> set) {
    return containerGrammar.Then(value.Map<TValue, Action<TContainer>>(v => container => set(container, v)));
  }
}

public static class GrammarBuilder {

  public static Grammar<T> Value<T>(T value) => new Value<T>(value);
  public static Grammar<Action<T>> Builder<T>() => new Value<Action<T>>(_ => { });
  public static Grammar Keyword(string keyword) => new Text(keyword);
  public static readonly Grammar<string> Identifier = new IdentifierG();
  public static readonly Grammar<int> Number = new NumberG();
}
