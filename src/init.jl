﻿"""

	init(".../nomad.3.9.1")

load NOMAD libraries and create C++ classes and functions
needed to handle NOMAD optimization process.

This function has to be called once before using `nomad()`.
It is automatically called when importing NOMAD.jl.

The only argument is a *String* containing the path to
the nomad.3.9.1 folder.

"""
function init(path_to_nomad::String)
	@info "loading NOMAD libraries"
	nomad_libs_call(path_to_nomad)
	create_Evaluator_class()
	create_Cresult_class()
	create_cxx_runner()
end

"""

	nomad_libs_call(".../nomad.3.9.1")

load libraries needed to run NOMAD.
Also include all headers to access via Cxx commands.

"""
function nomad_libs_call(path_to_nomad)
	try
		Libdl.dlopen(path_to_nomad * "/builds/release/lib/libnomad.so", Libdl.RTLD_GLOBAL)
	catch e
		@warn "NOMAD.jl error : initialization failed, cannot access NOMAD libraries. Try build NOMAD and relaunch Julia."
		throw(e)
	end

	try
		addHeaderDir(joinpath(path_to_nomad,"src"))
		addHeaderDir(joinpath(path_to_nomad,"ext/sgtelib/src"))
		cxxinclude("nomad.hpp")
	catch e
		@warn "NOMAD.jl error : initialization failed, headers folders cannot be found in NOMAD files"
		throw(e)
	end
end

"""

	create_Evaluator_class()

Create a C++ class `Wrap_Evaluator` that inherits from
the abstract class `NOMAD::Evaluator`.

"""
function create_Evaluator_class()

	#=
	The method eval_x is called by NOMAD to evaluate the
	values of objective functions and constraints for a
	given state. The first attribute evalwrap of the class
	is a pointer to the julia function that wraps the evaluator
	provided by the user and makes it interpretable by C++.
	This wrapper is called by the method eval_x. This way,
	each instance of the class Wrap_Evaluator is related
	to a given julia evaluator.

	the attribute n is the dimension of the problem and m
	is the number of outputs (objective functions and
	constraints).
	=#

    cxx"""
		#include <string>
		#include <limits>
		#include <vector>

		class Wrap_Evaluator : public NOMAD::Evaluator {

		public:

			double * (*evalwrap)(double * input);
			bool sgte;
			int n;
			int m;

		Wrap_Evaluator  ( const NOMAD::Parameters & p, double * (*f)(double * input), int input_dim, int output_dim, bool has_sgte) :

			NOMAD::Evaluator ( p ) {evalwrap=f; n=input_dim; m=output_dim; sgte=has_sgte;}

		~Wrap_Evaluator ( void ) {evalwrap=nullptr;}

		bool eval_x ( NOMAD::Eval_Point & x, const NOMAD::Double & h_max, bool & count_eval ) const {

			double c_x[n+1];
			for (int i = 0; i < n; ++i) {
				c_x[i]=x[i].value();
			} //first converting our NOMAD::Eval_Point to a double[]

			if (sgte) {
				c_x[n] = (x.get_eval_type()==NOMAD::SGTE)?1.0:0.0;
			} //last coordinate decides if we call the surrogate or not

			double * c_bb_outputs = evalwrap(c_x);

			for (int i = 0; i < m; ++i) {
				NOMAD::Double nomad_bb_output = c_bb_outputs[i];
				x.set_bb_output  ( i , nomad_bb_output  );
			} //converting C-double returned by evalwrap in NOMAD::Double that
			//are inserted in x as black box outputs

			bool success = false;
			if (c_bb_outputs[m]==1.0) {
				success=true;
			}//sucess and count_eval returned by evalwrap are actually doubles and need
			//to be converted to booleans

			count_eval = false;
			if (c_bb_outputs[m+1]==1.0) {
				count_eval=true;
			}

			delete[] c_bb_outputs;

			return success;

		}

		};
	"""
end

"""

	create_cxx_runner()

Create a C++ function cpp_runner that launches NOMAD
optimization process.

"""
function create_cxx_runner()

	#=
	This C++ function takes as arguments C++
	NOMAD::Parameters object along with a void
	pointer to the julia function that wraps the
	evaluator provided by the user. cpp_runner first
	converts this pointer to the appropriate type.
	Then, a Wrap_Evaluator is constructed from the
	NOMAD::Parameters instance and from the pointer
	to the evaluator wrapper. Finally, Mads is run,
	taking as arguments the Wrap_Evaluator and the
	NOMAD::Parameters instance.
	=#

    cxx"""
		#include <iostream>
		#include <string>
		#include <list>

		Cresult cpp_runner(NOMAD::Parameters * p,
					NOMAD::Display out,
					int n,
					int m,
					void* f_ptr,
					bool has_stat_avg_,
					bool has_stat_sum_,
					bool has_sgte_) {

		Cresult res; //This instance will store information about the run

		try {

			p->Parameters::check();

			//conversion from void pointer to appropriate pointer
			typedef double * (*fptr)(double * input);
			fptr f_fun_ptr = reinterpret_cast<fptr>(f_ptr);

			// custom evaluator creation
			Wrap_Evaluator ev   ( *p , f_fun_ptr, n, m, has_sgte_);

			// algorithm creation and execution
			NOMAD::Mads mads ( *p , &ev );

			mads.run();

			//saving results
			const NOMAD::Eval_Point* bf_ptr = mads.get_best_feasible();
			const NOMAD::Eval_Point* bi_ptr = mads.get_best_infeasible();
			res.set_eval_points(bf_ptr,bi_ptr,n,m);
			NOMAD::Stats stats;
			stats = mads.get_stats();
			res.bb_eval = stats.get_bb_eval();
			if (has_stat_avg_) {res.stat_avg = (stats.get_stat_avg()).value();}
			if (has_stat_sum_) {res.stat_sum = (stats.get_stat_sum()).value();}
			res.seed = p->get_seed();

			mads.reset();

			res.success = true;

			delete p;
		}
		catch ( exception & e ) {
			cerr << "\nNOMAD has been interrupted (" << e.what() << ")\n\n";
		}

		NOMAD::Slave::stop_slaves ( out );
		NOMAD::end();

		return res;

		}
    """
end

"""

	create_Cresult_class()

Create C++ class that store results from simulation.

"""
function create_Cresult_class()
    cxx"""
		class Cresult {

		public:

			//No const NOMAD::Eval_point pointer in Cresult because GC sometimes erase their content
			std::vector<double> bf;
			std::vector<double> bbo_bf;
			std::vector<double> bi;
			std::vector<double> bbo_bi;
			int bb_eval;
			double stat_avg;
			double stat_sum;
			bool success;
			bool has_feasible;
			bool has_infeasible;
			int seed;

		Cresult(){success=false;}

		void set_eval_points( const NOMAD::Eval_Point* bf_ptr, const NOMAD::Eval_Point* bi_ptr, int n, int m ) {

			has_feasible = (bf_ptr != NULL);

			if (has_feasible) {
				for (int i = 0; i < n; ++i) {
					bf.push_back(bf_ptr->value(i));
				}
				for (int i = 0; i < m; ++i) {
					bbo_bf.push_back((bf_ptr->get_bb_outputs())[i].value());
				}
			}

			has_infeasible = (bi_ptr != NULL);

			if (has_infeasible) {
				for (int i = 0; i < n; ++i) {
					bi.push_back(bi_ptr->value(i));
				}
				for (int i = 0; i < m; ++i) {
					bbo_bi.push_back((bi_ptr->get_bb_outputs())[i].value());
				}
			}
		}

		};
	"""
end
