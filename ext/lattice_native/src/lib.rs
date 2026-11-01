//! Ruby bindings for the Lattice engine (`Lattice::Engine::Model`).
//!
//! `Model.new(sizes, weights, strength, invalid_pairs, requires, higher_order, forced)`
//! takes a schema compiled to the engine's constraint primitives and answers:
//! `feasibility` (raises ForcedInfeasible with the forced interaction's index,
//! or NoValidAssignments), `can_complete?(assignments)`, and `generate(...)`.
use std::cell::RefCell;

use lattice_engine::{Assignment, Engine, Error as EngineError, Model as EngineModel, Options};
use magnus::{Error, ExceptionClass, Module, Ruby, function, method, prelude::*, value::Lazy};

type Pair = (Assignment, Assignment);

static ENGINE_ERROR: Lazy<ExceptionClass> = Lazy::new(|ruby| {
    ruby.class_object()
        .const_get::<_, magnus::RModule>("Lattice")
        .and_then(|lattice| lattice.const_get::<_, magnus::RModule>("Engine"))
        .and_then(|engine| engine.const_get("ForcedInfeasible"))
        .unwrap()
});

static NO_VALID: Lazy<ExceptionClass> = Lazy::new(|ruby| {
    ruby.class_object()
        .const_get::<_, magnus::RModule>("Lattice")
        .and_then(|lattice| lattice.const_get::<_, magnus::RModule>("Engine"))
        .and_then(|engine| engine.const_get("NoValidAssignments"))
        .unwrap()
});

fn to_ruby(ruby: &Ruby, error: EngineError) -> Error {
    match error {
        EngineError::ForcedInfeasible(index) => Error::new(ruby.get_inner(&ENGINE_ERROR), index.to_string()),
        EngineError::NoValidAssignments => Error::new(ruby.get_inner(&NO_VALID), "no valid assignments"),
        other => Error::new(ruby.exception_arg_error(), format!("{other:?}")),
    }
}

#[magnus::wrap(class = "Lattice::Engine::Model", free_immediately)]
struct Model(RefCell<Engine>);

impl Model {
    fn new(
        ruby: &Ruby,
        sizes: Vec<usize>,
        weights: Vec<Vec<f64>>,
        strength: usize,
        invalid_pairs: Vec<Pair>,
        requires: Vec<Pair>,
        higher_order: Vec<(Vec<Assignment>, Assignment)>,
        forced: Vec<Vec<Assignment>>,
    ) -> Result<Self, Error> {
        let model = EngineModel {
            sizes,
            weights,
            strength,
            invalid_pairs,
            requires,
            higher_order,
            forced,
        };
        Engine::new(model)
            .map(|engine| Model(RefCell::new(engine)))
            .map_err(|e| to_ruby(ruby, e))
    }

    fn feasibility(ruby: &Ruby, rb_self: &Self) -> Result<(), Error> {
        rb_self.0.borrow_mut().feasibility().map_err(|e| to_ruby(ruby, e))
    }

    fn can_complete(ruby: &Ruby, rb_self: &Self, assignments: Vec<Assignment>) -> Result<bool, Error> {
        rb_self
            .0
            .borrow_mut()
            .can_complete(&assignments)
            .map_err(|e| to_ruby(ruby, e))
    }

    /// Returns [rows ordered by coverage, new tuples per row, valid tuples].
    fn generate(
        ruby: &Ruby,
        rb_self: &Self,
        seed: u64,
        candidates: usize,
        shrink_steps: u64,
        patience: u64,
    ) -> Result<(Vec<Vec<usize>>, Vec<usize>, usize), Error> {
        let options = Options {
            seed,
            candidates: candidates.max(1),
            shrink_steps,
            patience,
        };
        let result = rb_self
            .0
            .borrow_mut()
            .generate(&options)
            .map_err(|e| to_ruby(ruby, e))?;
        Ok((result.rows, result.new_coverage, result.valid_tuples))
    }
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let engine = ruby.define_module("Lattice")?.define_module("Engine")?;
    let base = engine.define_error("Error", ruby.exception_standard_error())?;
    engine.define_error("ForcedInfeasible", base)?;
    engine.define_error("NoValidAssignments", base)?;
    let model = engine.define_class("Model", ruby.class_object())?;
    model.define_singleton_method("new", function!(Model::new, 7))?;
    model.define_method("feasibility", method!(Model::feasibility, 0))?;
    model.define_method("can_complete?", method!(Model::can_complete, 1))?;
    model.define_method("generate", method!(Model::generate, 4))?;
    Ok(())
}
