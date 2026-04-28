import Foundation

/// A typed dimension: a name + a list of typed values.
public struct MatrixDimension<T: Sendable>: Sendable {
    public let name: String
    public let values: [T]
    public init(_ name: String, _ values: [T]) {
        self.name = name
        self.values = values
    }
}

/// Generates pairwise-covering tuples over up to 8 typed dimensions.
/// Use the variadic-arity overloads up to 8; for more dimensions, drop to
/// `PairwiseCovering.generate` and index manually.
///
/// Example:
/// ```
/// for cell in ConfigurationMatrix.pairwise(
///     MatrixDimension("kind", ReactionKind.allCases),
///     MatrixDimension("master", [false, true]),
///     MatrixDimension("matrix", [false, true])
/// ) {
///     // cell.0 is ReactionKind, cell.1 is Bool, cell.2 is Bool
/// }
/// ```
public enum ConfigurationMatrix {
    public static func pairwise<A, B>(
        _ a: MatrixDimension<A>,
        _ b: MatrixDimension<B>
    ) -> [(A, B)] {
        let tuples = PairwiseCovering.generate(arities: [
            a.values.count, b.values.count
        ])
        return tuples.map { (a.values[$0[0]], b.values[$0[1]]) }
    }

    public static func pairwise<A, B, C>(
        _ a: MatrixDimension<A>,
        _ b: MatrixDimension<B>,
        _ c: MatrixDimension<C>
    ) -> [(A, B, C)] {
        let tuples = PairwiseCovering.generate(arities: [
            a.values.count, b.values.count, c.values.count
        ])
        return tuples.map { (a.values[$0[0]], b.values[$0[1]], c.values[$0[2]]) }
    }

    public static func pairwise<A, B, C, D>(
        _ a: MatrixDimension<A>,
        _ b: MatrixDimension<B>,
        _ c: MatrixDimension<C>,
        _ d: MatrixDimension<D>
    ) -> [(A, B, C, D)] {
        let tuples = PairwiseCovering.generate(arities: [
            a.values.count, b.values.count, c.values.count, d.values.count
        ])
        return tuples.map {
            (a.values[$0[0]], b.values[$0[1]], c.values[$0[2]], d.values[$0[3]])
        }
    }

    public static func pairwise<A, B, C, D, E>(
        _ a: MatrixDimension<A>,
        _ b: MatrixDimension<B>,
        _ c: MatrixDimension<C>,
        _ d: MatrixDimension<D>,
        _ e: MatrixDimension<E>
    ) -> [(A, B, C, D, E)] {
        let tuples = PairwiseCovering.generate(arities: [
            a.values.count, b.values.count, c.values.count, d.values.count,
            e.values.count
        ])
        return tuples.map {
            (a.values[$0[0]], b.values[$0[1]], c.values[$0[2]], d.values[$0[3]],
             e.values[$0[4]])
        }
    }

    public static func pairwise<A, B, C, D, E, F>(
        _ a: MatrixDimension<A>,
        _ b: MatrixDimension<B>,
        _ c: MatrixDimension<C>,
        _ d: MatrixDimension<D>,
        _ e: MatrixDimension<E>,
        _ f: MatrixDimension<F>
    ) -> [(A, B, C, D, E, F)] {
        let tuples = PairwiseCovering.generate(arities: [
            a.values.count, b.values.count, c.values.count, d.values.count,
            e.values.count, f.values.count
        ])
        return tuples.map {
            (a.values[$0[0]], b.values[$0[1]], c.values[$0[2]], d.values[$0[3]],
             e.values[$0[4]], f.values[$0[5]])
        }
    }

    public static func pairwise<A, B, C, D, E, F, G>(
        _ a: MatrixDimension<A>,
        _ b: MatrixDimension<B>,
        _ c: MatrixDimension<C>,
        _ d: MatrixDimension<D>,
        _ e: MatrixDimension<E>,
        _ f: MatrixDimension<F>,
        _ g: MatrixDimension<G>
    ) -> [(A, B, C, D, E, F, G)] {
        let tuples = PairwiseCovering.generate(arities: [
            a.values.count, b.values.count, c.values.count, d.values.count,
            e.values.count, f.values.count, g.values.count
        ])
        return tuples.map {
            (a.values[$0[0]], b.values[$0[1]], c.values[$0[2]], d.values[$0[3]],
             e.values[$0[4]], f.values[$0[5]], g.values[$0[6]])
        }
    }

    public static func pairwise<A, B, C, D, E, F, G, H>(
        _ a: MatrixDimension<A>,
        _ b: MatrixDimension<B>,
        _ c: MatrixDimension<C>,
        _ d: MatrixDimension<D>,
        _ e: MatrixDimension<E>,
        _ f: MatrixDimension<F>,
        _ g: MatrixDimension<G>,
        _ h: MatrixDimension<H>
    ) -> [(A, B, C, D, E, F, G, H)] {
        let tuples = PairwiseCovering.generate(arities: [
            a.values.count, b.values.count, c.values.count, d.values.count,
            e.values.count, f.values.count, g.values.count, h.values.count
        ])
        return tuples.map {
            (a.values[$0[0]], b.values[$0[1]], c.values[$0[2]], d.values[$0[3]],
             e.values[$0[4]], f.values[$0[5]], g.values[$0[6]], h.values[$0[7]])
        }
    }
}
