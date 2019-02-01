/*-------------------------------------------------------------------------
 *
 * nodeTidrangescan.c
 *	  Routines to support scanning a range of tids
 *
 * Portions Copyright (c) 1996-2018, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 *
 * IDENTIFICATION
 *	  src/backend/executor/nodeTidrangescan.c
 *
 *-------------------------------------------------------------------------
 */
/*
 * INTERFACE ROUTINES
 *
 *		ExecTidRangeScan			scans a relation using a range of tids.
 *		ExecInitTidRangeScan		creates and initializes state info.
 *		ExecReScanTidRangeScan		rescans the tid relation.
 *		ExecEndTidRangeScan			releases all storage.
 */
#include "postgres.h"

#include "access/relscan.h"
#include "access/sysattr.h"
#include "catalog/pg_type.h"
#include "executor/execdebug.h"
#include "executor/nodeTidrangescan.h"
#include "miscadmin.h"
#include "optimizer/clauses.h"
#include "storage/bufmgr.h"
#include "utils/rel.h"

static void TidRangeEvalBounds(TidRangeScanState *tidstate, BlockNumber rs_nblocks);
static TupleTableSlot *TidRangeNext(TidRangeScanState *node);
static bool TidRangeRecheck(TidRangeScanState *node, TupleTableSlot *slot);


static void
TidRangeEvalBounds(TidRangeScanState *tidstate, BlockNumber rs_nblocks)
{
	ExprContext *econtext = tidstate->ss.ps.ps_ExprContext;
	ItemPointer itemptr;
	bool        isNull;

	if (tidstate->lower_expr)
		itemptr = (ItemPointer)
			DatumGetPointer(ExecEvalExprSwitchContext(tidstate->lower_expr,
														econtext,
														&isNull));
	else
		isNull = true;

	if (!isNull)
	{
		tidstate->first_block = ItemPointerGetBlockNumberNoCheck(itemptr);
		tidstate->first_tuple = ItemPointerGetOffsetNumberNoCheck(itemptr);

		if (((TidRangeScan *) (tidstate->ss.ps.plan))->lower_strict)
		{
			tidstate->first_tuple++;
			if (tidstate->last_tuple == 0)
				tidstate->last_block++;
		}

		if (tidstate->first_block > 0 && tidstate->first_block >= rs_nblocks)
		{
			tidstate->first_block = 0;
			tidstate->blocks_to_scan = 0;
			return;
		}
	}
	else
	{
		tidstate->first_block = 0;
		tidstate->first_tuple = 0;
	}
	
	Assert(tidstate->first_block == 0 || tidstate->first_block < rs_nblocks);

	if (tidstate->upper_expr)
		itemptr = (ItemPointer)
			DatumGetPointer(ExecEvalExprSwitchContext(tidstate->upper_expr,
														econtext,
														&isNull));
	else
		isNull = true;

	if (!isNull)
	{
		tidstate->last_block = ItemPointerGetBlockNumberNoCheck(itemptr);
		tidstate->last_tuple = ItemPointerGetOffsetNumberNoCheck(itemptr);

		if (((TidRangeScan *) (tidstate->ss.ps.plan))->upper_strict)
		{
			/* If decrementing the last_tuple would cause last_block to underflow, don't do it. */
			if (tidstate->last_block == 0 && tidstate->last_tuple == 0)
			{
				tidstate->first_block = 0;
				tidstate->blocks_to_scan = 0;
				return;
			}
			else
			{
				if (tidstate->last_tuple == 0)
					tidstate->last_block--;
				tidstate->last_tuple--;
			}
		}
	}
	else
	{
		tidstate->last_block = InvalidBlockNumber;
		tidstate->last_tuple = MaxOffsetNumber;
	}
	
	tidstate->blocks_to_scan = BlockNumberIsValid(tidstate->last_block) ? (tidstate->last_block - tidstate->first_block + 1) : (rs_nblocks - tidstate->first_block);
}

/* ----------------------------------------------------------------
 *		TidRangeNext
 *
 *		Retrieve a tuple from the TidRangeScan node's currentRelation
 *		using a heap scan between the bounds in the TidRangeScanState.
 *
 * ----------------------------------------------------------------
 */
static TupleTableSlot *
TidRangeNext(TidRangeScanState *node)
{
	HeapTuple       tuple;
	HeapScanDesc    scandesc;
	EState         *estate;
	ScanDirection   direction;
	TupleTableSlot *slot;

	/*
	* get information from the estate and scan state
	*/
	scandesc = node->ss.ss_currentScanDesc;
	estate = node->ss.ps.state;
	direction = estate->es_direction;
	if (ScanDirectionIsBackward(((TidRangeScan *) node->ss.ps.plan)->direction))
	{
		if (ScanDirectionIsForward(direction))
			direction = BackwardScanDirection;
		else if (ScanDirectionIsBackward(direction))
			direction = ForwardScanDirection;
	}
	slot = node->ss.ss_ScanTupleSlot;

	/* compute bounds and start a new scan, if necessary */
	if (node->first_block == InvalidBlockNumber)
	{
		if (scandesc == NULL)
		{
			scandesc = heap_beginscan_strat(node->ss.ss_currentRelation,
											estate->es_snapshot,
											0, NULL,
											false, false);
			node->ss.ss_currentScanDesc = scandesc;
		}

		TidRangeEvalBounds(node, scandesc->rs_nblocks);

	    heap_setscanlimits(scandesc, node->first_block, node->blocks_to_scan);
		printf("set scan limits to %d, %d\n", node->first_block, node->blocks_to_scan);
	}

	/*
	* get the next tuple from the table
	*/
	for (;;)
	{
		BlockNumber block;
		OffsetNumber offset;

		tuple = heap_getnext(scandesc, direction);
		if (!tuple)
			break;

		block = ItemPointerGetBlockNumber(&tuple->t_self);
		offset = ItemPointerGetOffsetNumber(&tuple->t_self);

		if (block == node->first_block && offset < node->first_tuple)
			continue;

		if (block == node->last_block && offset > node->last_tuple)
			continue;

		break;
	}

	/*
	* save the tuple and the buffer returned to us by the access methods in
	* our scan tuple slot and return the slot.  Note: we pass 'false' because
	* tuples returned by heap_getnext() are pointers onto disk pages and were
	* not created with palloc() and so should not be pfree()'d.  Note also
	* that ExecStoreTuple will increment the refcount of the buffer; the
	* refcount will not be dropped until the tuple table slot is cleared.
	*/
	if (tuple)
	   ExecStoreTuple(tuple,   /* tuple to store */
					  slot,    /* slot to store in */
					  scandesc->rs_cbuf,   /* buffer associated with this
											* tuple */
					  false);  /* don't pfree this pointer */
	else
	   ExecClearTuple(slot);

	return slot;
}

/*
 * TidRangeRecheck -- access method routine to recheck a tuple in EvalPlanQual
 */
static bool
TidRangeRecheck(TidRangeScanState *node, TupleTableSlot *slot)
{
	return true;
}


/* ----------------------------------------------------------------
 *		ExecTidRangeScan(node)
 *
 *		Scans the relation using tids and returns
 *		   the next qualifying tuple in the direction specified.
 *		We call the ExecScan() routine and pass it the appropriate
 *		access method functions.
 *
 *		Conditions:
 *		  -- the "cursor" maintained by the AMI is positioned at the tuple
 *			 returned previously.
 *
 *		Initial States:
 *		  -- the relation indicated is opened for scanning so that the
 *			 "cursor" is positioned before the first qualifying tuple.
 *		  -- tidPtr is -1.
 * ----------------------------------------------------------------
 */
static TupleTableSlot *
ExecTidRangeScan(PlanState *pstate)
{
	TidRangeScanState *node = castNode(TidRangeScanState, pstate);

	return ExecScan(&node->ss,
					(ExecScanAccessMtd) TidRangeNext,
					(ExecScanRecheckMtd) TidRangeRecheck);
}

/* ----------------------------------------------------------------
 *		ExecReScanTidRangeScan(node)
 * ----------------------------------------------------------------
 */
void
ExecReScanTidRangeScan(TidRangeScanState *node)
{
	HeapScanDesc scan = node->ss.ss_currentScanDesc;

	if (scan != NULL)
		heap_rescan(scan,       /* scan desc */
					NULL);      /* new scan keys */

	/* mark tid range as not computed yet */
	node->first_block = InvalidBlockNumber;

	ExecScanReScan(&node->ss);
}

/* ----------------------------------------------------------------
 *		ExecEndTidRangeScan
 *
 *		Releases any storage allocated through C routines.
 *		Returns nothing.
 * ----------------------------------------------------------------
 */
void
ExecEndTidRangeScan(TidRangeScanState *node)
{
	HeapScanDesc scan = node->ss.ss_currentScanDesc;

	/*
	 * Free the exprcontext
	 */
	ExecFreeExprContext(&node->ss.ps);

	/*
	 * clear out tuple table slots
	 */
	ExecClearTuple(node->ss.ps.ps_ResultTupleSlot);
	ExecClearTuple(node->ss.ss_ScanTupleSlot);

	/* close heap scan */
	if (scan != NULL)
		heap_endscan(scan);

	/*
	 * close the heap relation.
	 */
	ExecCloseScanRelation(node->ss.ss_currentRelation);
}

/* ----------------------------------------------------------------
 *		ExecInitTidRangeScan
 *
 *		Initializes the tid scan's state information, creates
 *		scan keys, and opens the base and tid relations.
 *
 *		Parameters:
 *		  node: TidNode node produced by the planner.
 *		  estate: the execution state initialized in InitPlan.
 * ----------------------------------------------------------------
 */
TidRangeScanState *
ExecInitTidRangeScan(TidRangeScan *node, EState *estate, int eflags)
{
	TidRangeScanState *tidstate;
	Relation	currentRelation;

	/*
	 * create state structure
	 */
	tidstate = makeNode(TidRangeScanState);
	tidstate->ss.ps.plan = (Plan *) node;
	tidstate->ss.ps.state = estate;
	tidstate->ss.ps.ExecProcNode = ExecTidRangeScan;

	/*
	 * Miscellaneous initialization
	 *
	 * create expression context for node
	 */
	ExecAssignExprContext(estate, &tidstate->ss.ps);

	/*
	 * mark tid range as not computed yet (note that only
	 * first_block == InvalidBlockNumber is necessary; the
	 * others are just for consistency)
	 */
	tidstate->first_block = InvalidBlockNumber;
	tidstate->first_tuple = InvalidOffsetNumber;
	tidstate->last_block = InvalidBlockNumber;
	tidstate->last_tuple = InvalidOffsetNumber;

	/*
	 * open the base relation and acquire appropriate lock on it.
	 */
	currentRelation = ExecOpenScanRelation(estate, node->scan.scanrelid, eflags);

	tidstate->ss.ss_currentRelation = currentRelation;
	tidstate->ss.ss_currentScanDesc = NULL; /* no heap scan here */

	/*
	 * get the scan type from the relation descriptor.
	 */
	ExecInitScanTupleSlot(estate, &tidstate->ss,
						  RelationGetDescr(currentRelation));

	/*
	 * Initialize result slot, type and projection.
	 */
	ExecInitResultTupleSlotTL(estate, &tidstate->ss.ps);
	ExecAssignScanProjectionInfo(&tidstate->ss);

	/*
	 * initialize child expressions
	 */
	tidstate->ss.ps.qual =
		ExecInitQual(node->scan.plan.qual, (PlanState *) tidstate);

	tidstate->lower_expr = ExecInitExpr((Expr *) node->lower_bound, &tidstate->ss.ps);
	tidstate->upper_expr = ExecInitExpr((Expr *) node->upper_bound, &tidstate->ss.ps);

	/*
	 * all done.
	 */
	return tidstate;
}
